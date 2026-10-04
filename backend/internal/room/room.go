// Package room owns live tables.
//
// Each table is one goroutine that exclusively owns its state: the engine, the
// seats, the pacing timers and the client handles. Nothing outside touches that
// state — callers post messages to an inbox and the actor applies them in
// order. That is what makes turn ordering trivially correct and removes every
// lock from the hot path.
//
// The behaviour mirrors LanHostSession in the Godot client
// (godot/scripts/net/lan_host_session.gd), which is the reference host: a
// lobby that fills with guests, a host who starts the game, bots on the empty
// seats, and a publish-then-schedule loop that paces the table. The server adds
// what an untrusted, unreliable network needs — turn clocks, bot takeover for
// dropped players, and consent gates so one player cannot skip the scoreboard
// for everybody else.
package room

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"log/slog"
	mrand "math/rand/v2"
	"sync/atomic"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/bot"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// Client is the room's view of a connected player. Implementations must make
// Send non-blocking: a room must never stall because one phone stopped reading.
type Client interface {
	// Send queues one encoded frame. Dropping it when the queue is full is
	// correct — a client that far behind is getting closed anyway.
	Send(frame []byte)
	// Fail sends a fatal error frame and closes the connection once that frame
	// is actually on the wire, so a client that loses its seat (or the match,
	// or its place in the queue) always learns why instead of getting a bare
	// "disconnected". Implementations must never close before the frame is
	// written.
	Fail(code, message string)
	// Close ends the connection after flushing what it can.
	Close(code, reason string)
	// PlayerID is the guest identity behind this socket.
	PlayerID() auth.GuestID
}

// BotNames fill empty seats, matching the names the offline client uses.
var BotNames = [3]string{"Amit", "Riya", "Sujan"}

// Pacing groups every duration a table runs on, so tests can compress them.
type Pacing struct {
	BotThinkMin   time.Duration
	BotThinkExtra time.Duration
	TrickLinger   time.Duration
	BidTimeout    time.Duration
	// PlayTimeouts is how long a seat has to play a card, indexed by how many
	// cards are already down this trick: the leader thinks longest, and each
	// seat after has less to decide with more of the trick already on the
	// table.
	PlayTimeouts    [4]time.Duration
	ReconnectGrace  time.Duration
	HandAdvanceWait time.Duration
	IdleTTL         time.Duration
	StartCountdown  time.Duration
	// DealGrace is how long after the deal bidding opens, so the dealing
	// animation has finished on every screen before anyone bids.
	DealGrace time.Duration
}

// FlatPlayTimeouts is a PlayTimeouts array using the same duration for every
// trick position, for callers — mainly tests — that do not care about the
// graduation.
func FlatPlayTimeouts(d time.Duration) [4]time.Duration {
	return [4]time.Duration{d, d, d, d}
}

// DefaultPacing matches the pacing constants in godot/scripts/net/game_session.gd.
func DefaultPacing() Pacing {
	return Pacing{
		BotThinkMin:     550 * time.Millisecond,
		BotThinkExtra:   450 * time.Millisecond,
		TrickLinger:     1100 * time.Millisecond,
		BidTimeout:      5 * time.Second,
		PlayTimeouts:    [4]time.Duration{10 * time.Second, 8 * time.Second, 6 * time.Second, 5 * time.Second},
		ReconnectGrace:  2 * time.Minute,
		HandAdvanceWait: 5 * time.Second,
		IdleTTL:         5 * time.Minute,
		StartCountdown:  3 * time.Second,
		DealGrace:       3500 * time.Millisecond,
	}
}

// seat is one place at the table.
type seat struct {
	occupied  bool
	player    auth.GuestID
	name      string
	kind      engine.PlayerKind
	client    Client
	connected bool
	// confirmed is set once the gateway has told this client its seat number.
	// Until then the room sends it nothing: a lobby or a view is written from a
	// seat's point of view and is meaningless — or misleading — to a client that
	// does not yet know which seat it got.
	confirmed bool
	// consented is this seat's agreement to leave the between-hands scoreboard.
	consented bool
	// userID is the persistent account behind this seat, when the gateway could
	// resolve one. Empty for a bot, for an old client, and whenever persistence
	// is off — identity is an enrichment of the session, never a precondition
	// for it (docs/PERSISTENCE.md §4.1).
	userID string
	// autoplay is set once this seat has let a turn clock expire. The server
	// then plays every subsequent move for them until they come back, which is
	// far better than making the rest of the table wait out a full clock on
	// every single turn of a player who has walked away.
	autoplay bool
	// graceUntil is when a dropped player loses the seat for good.
	graceUntil time.Time
	difficulty engine.Difficulty
}

func (s *seat) isHumanSeat() bool { return s.occupied && s.kind == engine.KindHuman }

// serverDriven reports that the server must play this seat: a bot, a human who
// is not connected, or one who has handed over to autoplay by letting their
// clock run out.
func (s *seat) serverDriven() bool {
	return s.occupied && (s.kind == engine.KindBot || !s.connected || s.autoplay)
}

// Options configure a new room.
type Options struct {
	ID         string
	Mode       protocol.Mode
	Pacing     Pacing
	Signer     *auth.Signer
	Logger     *slog.Logger
	TotalHands int
	// Deal is how each hand is shuffled and distributed. The zero value is the
	// fair default (uniform shuffle, sequential cut); it is chosen at table
	// creation from the joining client's preference and never changes after.
	Deal engine.DealConfig
	// AutoStart deals on its own once the table has enough players, rather than
	// waiting for a host to press start. Quickplay tables use it.
	AutoStart bool
	// MinPlayers is how many humans must be present before AutoStart will deal.
	// Quickplay sets it to 2: one human against three bots is the offline game,
	// not a match against people.
	MinPlayers int
	// FillWait is how long an AutoStart table holds the door open for more
	// players once it has MinPlayers, before dealing with bots on the rest.
	FillWait time.Duration
	// OnClosed is called once, from the actor goroutine, as the room exits.
	OnClosed func(id string)
	// Recorder persists finished games. Nil — or one built over a disabled
	// store — means the table plays exactly as it always has and nothing is
	// written.
	Recorder *Recorder
}

// Room is a live table. All exported methods are safe to call from any
// goroutine; they post to the actor and return immediately.
type Room struct {
	id     string
	mode   protocol.Mode
	pacing Pacing
	signer *auth.Signer
	log    *slog.Logger
	opts   Options

	inbox  chan message
	done   chan struct{}
	closed chan struct{}

	// accepting is readable from any goroutine, unlike the actor-owned state
	// below. The matchmaker uses it to skip tables that have already dealt or
	// closed without having to interrogate the actor.
	accepting atomic.Bool

	// ---- actor-owned state below this line; never touch it from outside ----
	seats    [4]seat
	hostSeat int
	started  bool
	// startedAt is when the first hand was dealt; the dashboard shows it so an
	// operator can see how long a table has been running. Zero until then.
	startedAt time.Time
	// dealtAt is when the hand in progress was dealt. Bidding opens
	// [Pacing.DealGrace] after it, once the dealing animation is over on every
	// screen — see scheduleNextAction.
	dealtAt time.Time
	game    *engine.Game
	brains  [4]*bot.Brain
	rng     *mrand.Rand
	deadlines
	lastActivity time.Time
	countdownAt  time.Time
	totalHands   int
	// rec is the scoreboard accumulated for the game in progress. Actor-owned
	// like everything else here; the only thing that ever leaves the goroutine
	// is the finished record, handed to the recorder's queue.
	rec gameLog
	// recorder is shared and safe for concurrent use; the actor only ever calls
	// its non-blocking Submit.
	recorder *Recorder
}

// New starts a room actor. The returned room is live immediately; the caller
// must eventually call Close or cancel ctx.
func New(ctx context.Context, opts Options) *Room {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.TotalHands <= 0 {
		opts.TotalHands = engine.HandsPerGame
	}
	r := &Room{
		id:           opts.ID,
		mode:         opts.Mode,
		pacing:       opts.Pacing,
		signer:       opts.Signer,
		log:          opts.Logger.With("room", opts.ID, "mode", string(opts.Mode)),
		opts:         opts,
		inbox:        make(chan message, 64),
		done:         make(chan struct{}),
		closed:       make(chan struct{}),
		hostSeat:     -1,
		rng:          newRNG(),
		lastActivity: time.Now(),
		totalHands:   opts.TotalHands,
		recorder:     opts.Recorder,
	}
	r.idleAt = time.Now().Add(opts.Pacing.IdleTTL)
	r.accepting.Store(true)
	go r.run(ctx)
	return r
}

// Accepting reports whether this table can still take a new player: it has not
// dealt and has not closed. Safe to call from any goroutine.
func (r *Room) Accepting() bool { return r.accepting.Load() }

// MinPlayers is how many humans this table needs before it will deal itself.
func (r *Room) MinPlayers() int {
	if r.opts.MinPlayers < 1 {
		return 1
	}
	return r.opts.MinPlayers
}

// ID is the room code clients join with.
func (r *Room) ID() string { return r.id }

// Mode is which product surface this table belongs to.
func (r *Room) Mode() protocol.Mode { return r.mode }

// Done is closed once the actor has exited.
func (r *Room) Done() <-chan struct{} { return r.closed }

func newRNG() *mrand.Rand {
	var seed [16]byte
	if _, err := rand.Read(seed[:]); err != nil {
		panic("room: no entropy available: " + err.Error())
	}
	return mrand.New(mrand.NewPCG(
		binary.LittleEndian.Uint64(seed[0:8]),
		binary.LittleEndian.Uint64(seed[8:16]),
	))
}

// ------------------------------------------------------------------ actor loop

func (r *Room) run(ctx context.Context) {
	defer close(r.closed)
	defer r.accepting.Store(false)
	defer func() {
		if r.opts.OnClosed != nil {
			r.opts.OnClosed(r.id)
		}
		obs.RoomsActive.Dec()
	}()
	obs.RoomsActive.Inc()

	// A panic in game logic must cost one table, not the process. Everyone at
	// the table is told to go away rather than left staring at a dead socket.
	defer func() {
		if p := recover(); p != nil {
			r.log.Error("room panicked", "panic", p)
			for i := range r.seats {
				if c := r.seats[i].client; c != nil {
					c.Send(protocol.Encode(protocol.NewError(
						protocol.ErrInternal, "The table hit an internal error.", true)))
					c.Close("internal", "internal error")
				}
			}
		}
	}()

	timer := time.NewTimer(time.Hour)
	defer timer.Stop()

	for {
		r.armTimer(timer)

		select {
		case <-ctx.Done():
			r.shutdown("server_shutdown")
			return
		case <-r.done:
			r.shutdown("closed")
			return
		case <-timer.C:
			start := time.Now()
			if r.tick() {
				return
			}
			obs.RoomStep.Observe(time.Since(start).Seconds())
		case msg := <-r.inbox:
			start := time.Now()
			r.handle(msg)
			obs.RoomStep.Observe(time.Since(start).Seconds())
		}
	}
}

// armTimer resets timer to the earliest pending deadline. Go timers are cheap
// to reset and a single one keeps the select small.
func (r *Room) armTimer(timer *time.Timer) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	next, ok := r.nextDeadline()
	if !ok {
		timer.Reset(time.Hour)
		return
	}
	d := time.Until(next)
	if d < 0 {
		d = 0
	}
	timer.Reset(d)
}

// post hands a message to the actor, giving up if the room is already gone.
func (r *Room) post(m message) bool {
	select {
	case r.inbox <- m:
		return true
	case <-r.closed:
		return false
	}
}

// Close asks the actor to stop. Safe to call more than once.
func (r *Room) Close() {
	select {
	case <-r.done:
	default:
		close(r.done)
	}
}

func (r *Room) shutdown(reason string) {
	// A table that closes mid-game still owes its players a history row. This is
	// the single teardown funnel — an idle collection, an explicit Close and a
	// cancelled server context all pass through here — so one call covers every
	// way a game can be abandoned. It is a no-op once the game has been recorded
	// at its GameOver.
	r.abandonRecording()

	for i := range r.seats {
		if c := r.seats[i].client; c != nil {
			c.Send(protocol.Encode(protocol.NewError(
				protocol.ErrServerDraining,
				"This table is shutting down. Reconnect to resume.",
				true,
			)))
			c.Close("going_away", reason)
		}
	}
}
