package room

import (
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// RoomCodeAlphabet matches the one the Godot join sheet generates from
// (godot/scripts/ui/screens/join_sheet.gd): no I, O, 0 or 1, because they
// are the characters people misread when a code is spoken aloud.
const RoomCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// RoomCodeLength is what the client generates and what people type.
const RoomCodeLength = 4

var (
	// ErrAtCapacity means this node is holding as many tables as it is allowed.
	ErrAtCapacity = errors.New("room: node is at capacity")
	// ErrNotFound means no such table exists here.
	ErrNotFound = errors.New("room: no such table")
)

// AutoStart configures a table that deals itself rather than waiting for a host
// to press start. The zero value means "host-driven", which is what private
// tables want.
type AutoStart struct {
	// MinPlayers is how many humans must be present before the table will deal.
	MinPlayers int
	// FillWait is how long it holds the door open for more players once it has
	// MinPlayers.
	FillWait time.Duration
}

// Enabled reports whether this table deals itself.
func (a AutoStart) Enabled() bool { return a.MinPlayers > 0 }

// Registry records which node owns which table, so a client that reaches the
// wrong node can be redirected. The single-node deployment leaves it nil.
type Registry interface {
	Claim(room string)
	Release(room string)
}

// PacingSource is the live source of table pacing. A hub built with a static
// Pacing still works; wiring a source in is what lets the admin dashboard
// change timings without a restart. New tables read it at creation — an
// existing table keeps the pacing it was dealt, like every other creation-time
// choice it made.
type PacingSource interface {
	Pacing() Pacing
}

// Hub owns every table on this node.
//
// Its lock is held only long enough to look up or insert a room pointer — never
// across game logic, which lives entirely inside the room actors. That keeps
// the map from becoming a global bottleneck as table count grows.
type Hub struct {
	mu    sync.RWMutex
	rooms map[string]*Room

	ctx    context.Context
	pacing Pacing
	// PacingSource, when set, wins over pacing for every table created after.
	// See PacingSource.
	PacingSource PacingSource
	signer       *auth.Signer
	log          *slog.Logger
	maxRooms     int

	// Registry is optional; when set, the hub keeps it in step with the tables
	// it actually holds. Doing it here rather than at the call sites means a
	// claim can never outlive the room it points at.
	Registry Registry

	// Recorder is optional and is handed to every table this hub opens, so
	// persistence is configured in one place rather than at each creation site.
	// Set it before the first table is created — main does it at startup. Nil,
	// or one built over a disabled store, means nothing is recorded and play is
	// unchanged.
	Recorder *Recorder

	// activeMu guards active, which tracks which started table each player
	// currently holds a live human seat at. It is separate from mu because it
	// is written from inside room actor goroutines (via OnSeated/OnVacated),
	// not just from Hub's own lookup/insert path.
	activeMu sync.RWMutex
	active   map[auth.GuestID]string
}

func NewHub(ctx context.Context, pacing Pacing, signer *auth.Signer, log *slog.Logger, maxRooms int) *Hub {
	if log == nil {
		log = slog.Default()
	}
	return &Hub{
		rooms:    make(map[string]*Room),
		ctx:      ctx,
		pacing:   pacing,
		signer:   signer,
		log:      log,
		maxRooms: maxRooms,
		active:   make(map[auth.GuestID]string),
	}
}

// Get returns an existing table.
func (h *Hub) Get(id string) (*Room, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	r, ok := h.rooms[id]
	return r, ok
}

// currentPacing is the pacing a brand-new table is created with: the live
// source's value when one is wired, the static snapshot otherwise.
func (h *Hub) currentPacing() Pacing {
	if h.PacingSource != nil {
		return h.PacingSource.Pacing()
	}
	return h.pacing
}

// GetOrCreate returns the table with this id, creating it if it is not here
// yet. created reports which happened, so the caller can tell a room's
// creator from someone who joined it. totalHands and deal only take effect on
// creation — an existing table keeps whatever it was created with.
func (h *Hub) GetOrCreate(id string, mode protocol.Mode, auto AutoStart, totalHands int, deal engine.DealConfig) (r *Room, created bool, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if existing, ok := h.rooms[id]; ok {
		return existing, false, nil
	}
	if len(h.rooms) >= h.maxRooms {
		return nil, false, ErrAtCapacity
	}
	room := New(h.ctx, Options{
		ID:         id,
		Mode:       mode,
		Pacing:     h.currentPacing(),
		Signer:     h.signer,
		Logger:     h.log,
		TotalHands: totalHands,
		Deal:       deal,
		AutoStart:  auto.Enabled(),
		MinPlayers: auto.MinPlayers,
		FillWait:   auto.FillWait,
		OnClosed:   h.forget,
		Recorder:   h.Recorder,
	})
	h.rooms[id] = room
	h.claim(id)
	return room, true, nil
}

// CreateUnique makes a table under a freshly generated code, for quickplay
// where nobody typed a room in.
func (h *Hub) CreateUnique(mode protocol.Mode, auto AutoStart, totalHands int, deal engine.DealConfig) (*Room, error) {
	for attempt := 0; attempt < 32; attempt++ {
		id := NewRoomCode()
		h.mu.Lock()
		if _, taken := h.rooms[id]; taken {
			h.mu.Unlock()
			continue
		}
		if len(h.rooms) >= h.maxRooms {
			h.mu.Unlock()
			return nil, ErrAtCapacity
		}
		room := New(h.ctx, Options{
			ID:         id,
			Mode:       mode,
			Pacing:     h.currentPacing(),
			Signer:     h.signer,
			Logger:     h.log,
			TotalHands: totalHands,
			Deal:       deal,
			AutoStart:  auto.Enabled(),
			MinPlayers: auto.MinPlayers,
			FillWait:   auto.FillWait,
			OnClosed:   h.forget,
			Recorder:   h.Recorder,
		})
		h.rooms[id] = room
		h.mu.Unlock()
		h.claim(id)
		return room, nil
	}
	// 32 collisions in a row means the code space is saturated, not that we got
	// unlucky — a longer code would be the fix, so say so plainly.
	return nil, errors.New("room: could not find a free room code")
}

// forget drops a room from the map. Called by the room itself as it exits, so
// a table is never reachable after its actor has stopped.
func (h *Hub) forget(id string) {
	h.mu.Lock()
	delete(h.rooms, id)
	registry := h.Registry
	h.mu.Unlock()

	// Backstop: a room that closes without every seat having gone through
	// expireSeat (idle collection, a panic recovery, shutdown) must not leave
	// a player permanently flagged as "still playing" a table that is gone.
	h.activeMu.Lock()
	for player, room := range h.active {
		if room == id {
			delete(h.active, player)
		}
	}
	h.activeMu.Unlock()

	if registry != nil {
		registry.Release(id)
	}
}

// markSeated records that player now holds a live human seat at a started
// table. Called from inside a room actor's own goroutine (via OnSeated), once
// per join that lands them at a dealt table.
func (h *Hub) markSeated(player auth.GuestID, room string) {
	if player == "" {
		return
	}
	h.activeMu.Lock()
	h.active[player] = room
	h.activeMu.Unlock()
}

// markVacated records that player no longer holds that seat. It only clears
// the entry if it still points at room, so a vacate for a seat the player has
// since left cannot clobber a newer one they hold elsewhere.
func (h *Hub) markVacated(player auth.GuestID, room string) {
	if player == "" {
		return
	}
	h.activeMu.Lock()
	if h.active[player] == room {
		delete(h.active, player)
	}
	h.activeMu.Unlock()
}

// ActiveSeat reports the table a player currently holds a live human seat at,
// if any. Quickplay uses it to avoid silently seating someone at a second
// table while their first match is still going.
func (h *Hub) ActiveSeat(player auth.GuestID) (room string, ok bool) {
	h.activeMu.RLock()
	defer h.activeMu.RUnlock()
	room, ok = h.active[player]
	return room, ok
}

func (h *Hub) claim(id string) {
	if h.Registry != nil {
		h.Registry.Claim(id)
	}
}

// Count is how many tables this node currently holds.
func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.rooms)
}

// Snapshot returns every live room, for shutdown and for operational endpoints.
func (h *Hub) Snapshot() []*Room {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]*Room, 0, len(h.rooms))
	for _, r := range h.rooms {
		out = append(out, r)
	}
	return out
}

// CloseAll stops every table and waits for their actors to exit.
func (h *Hub) CloseAll() {
	rooms := h.Snapshot()
	for _, r := range rooms {
		r.Close()
	}
	for _, r := range rooms {
		<-r.Done()
	}
}

// NewRoomCode generates a code in the same shape the client produces, using
// rejection-free indexing into a 32-character alphabet (a power of two, so a
// masked random byte is uniform).
func NewRoomCode() string {
	buf := make([]byte, RoomCodeLength)
	if _, err := rand.Read(buf); err != nil {
		panic("room: no entropy available: " + err.Error())
	}
	out := make([]byte, RoomCodeLength)
	for i, b := range buf {
		out[i] = RoomCodeAlphabet[int(b)&31]
	}
	return string(out)
}

// ValidRoomCode reports whether a client-supplied code is one this server would
// have generated. Rejecting the rest early keeps junk out of the room map.
func ValidRoomCode(code string) bool {
	if len(code) < 3 || len(code) > protocol.MaxRoomRunes {
		return false
	}
	for _, c := range code {
		if !isCodeRune(byte(c)) || c > 127 {
			return false
		}
	}
	return true
}

func isCodeRune(c byte) bool {
	for i := 0; i < len(RoomCodeAlphabet); i++ {
		if RoomCodeAlphabet[i] == c {
			return true
		}
	}
	return false
}
