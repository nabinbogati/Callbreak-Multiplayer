// Package match seats quickplay players.
//
// There is no anonymous queue. A player asking for a quickplay game is put into
// a real table straight away, alongside whoever else is waiting, and the table
// deals itself once enough people are sitting at it. That is what lets players
// see each other's names while they wait instead of watching a counter, and it
// is why leaving is just leaving a table rather than a separate cancel path.
//
// The rule the table itself enforces (in package room) is that quickplay never
// deals below its minimum of real people: one human against three bots is the
// offline game, not a match.
package match

import (
	"log/slog"
	"sync"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// Params is the live source of quickplay defaults. The broker is built with
// static values (tests, or a server that never changes them); wiring a source
// in is what lets the admin dashboard tune matchmaking without a restart.
type Params interface {
	MatchMinPlayers() int
	MatchFillWait() time.Duration
}

// Broker hands out seats at quickplay tables.
//
// It holds a short list of tables that are still filling, one bucket per hand
// count (3 or 5), so a player asking for a 3-hand game and one asking for a
// 5-hand game are never seated together. Within a bucket, new players go into
// the oldest table with room, so a single table fills up before a second is
// opened — four people waiting for the same variant should end up at one
// table, not spread thinly across four.
type Broker struct {
	hub *room.Hub
	log *slog.Logger

	minPlayers int
	fillWait   time.Duration

	// Live, when set, wins over minPlayers/fillWait for every table opened
	// after the change. See Params.
	Live Params

	mu   sync.Mutex
	open map[int][]*room.Room
}

func New(hub *room.Hub, log *slog.Logger, minPlayers int, fillWait time.Duration) *Broker {
	if log == nil {
		log = slog.Default()
	}
	if minPlayers < 1 {
		minPlayers = 1
	}
	return &Broker{hub: hub, log: log, minPlayers: minPlayers, fillWait: fillWait, open: make(map[int][]*room.Room)}
}

// Seat puts a player at a quickplay table playing handsPerGame hands, opening
// one if every table of that variant that is still filling has run out of
// seats. A 3-hand seeker and a 5-hand seeker never end up in the same bucket,
// so they can never land at the same table.
func (b *Broker) Seat(req room.JoinRequest, handsPerGame int, deal engine.DealConfig) (*room.Room, room.JoinResult) {
	b.mu.Lock()
	defer b.mu.Unlock()

	minPlayers, fillWait := b.minPlayers, b.fillWait
	if b.Live != nil {
		minPlayers = b.Live.MatchMinPlayers()
		fillWait = b.Live.MatchFillWait()
	}

	b.prune()

	// Try the tables already forming for this variant, oldest first, so people
	// gather.
	for _, table := range b.open[handsPerGame] {
		res := table.Join(req)
		if res.Err == "" {
			b.publishDepth()
			return table, res
		}
		// A refusal means this table filled or dealt between the prune above and
		// now. Drop it and try the next.
		b.log.Debug("quickplay table refused a join", "room", table.ID(), "code", res.Err)
	}

	table, err := b.hub.CreateUnique(protocol.ModeOnline, room.AutoStart{
		MinPlayers: minPlayers,
		FillWait:   fillWait,
	}, handsPerGame, deal)
	if err != nil {
		b.log.Error("could not open a quickplay table", "err", err)
		return nil, room.JoinResult{
			Err:     protocol.ErrCapacity,
			ErrText: "No tables are available right now. Try again in a moment.",
		}
	}

	res := table.Join(req)
	if res.Err != "" {
		// A brand-new table refusing its first player means something is wrong
		// with the table, not with the player.
		table.Close()
		return nil, res
	}

	b.open[handsPerGame] = append(b.open[handsPerGame], table)
	b.publishDepth()
	return table, res
}

// prune drops tables that have dealt or closed, across every variant bucket.
// Both are reported by the table's own atomic flag, so this needs no round
// trip to the actor.
func (b *Broker) prune() {
	for handsPerGame, tables := range b.open {
		kept := tables[:0]
		for _, table := range tables {
			if table.Accepting() {
				kept = append(kept, table)
			}
		}
		// Release the tail so closed rooms are not pinned in the backing array.
		for i := len(kept); i < len(tables); i++ {
			tables[i] = nil
		}
		b.open[handsPerGame] = kept
	}
}

// publishDepth reports how many tables are mid-fill, which is the closest
// equivalent to "queue depth" now that there is no queue. Summed across every
// variant bucket — there is no per-variant metric. Called with the lock held.
func (b *Broker) publishDepth() {
	obs.QueueDepth.Set(float64(b.openLocked()))
}

// Open is how many tables are currently filling, across every variant, for
// tests and diagnostics.
func (b *Broker) Open() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.prune()
	return b.openLocked()
}

// openLocked sums the size of every bucket. Called with the lock held.
func (b *Broker) openLocked() int {
	n := 0
	for _, tables := range b.open {
		n += len(tables)
	}
	return n
}
