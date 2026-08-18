package room

import (
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// statusMsg asks the actor for a read-only snapshot of everything it owns.
// It is the only message that does not count as table activity, so a dashboard
// polling every few seconds cannot keep an empty room alive past its idle TTL.
type statusMsg struct {
	reply chan Status
}

func (statusMsg) isRoomMessage() {}

// Snapshot returns a full picture of the table: every seat, the game state,
// every pending clock and the pacing the table runs on. The caller sees a
// copy, so the actor can move on the instant the snapshot is built.
func (r *Room) Snapshot() Status {
	reply := make(chan Status, 1)
	if !r.post(statusMsg{reply: reply}) {
		return Status{ID: r.id, Mode: r.mode, Closed: true}
	}
	select {
	case s := <-reply:
		return s
	case <-r.closed:
		return Status{ID: r.id, Mode: r.mode, Closed: true}
	}
}

// Status is one point-in-time view of a live table, for the admin surface.
// Every field is a copy; nothing in it aliases actor-owned state.
type Status struct {
	ID        string
	Mode      protocol.Mode
	Closed    bool
	Accepting bool
	Started   bool
	// StartedAt is when the first hand was dealt; zero until then.
	StartedAt  time.Time
	LastActive time.Time
	TotalHands int
	HostSeat   int

	// Engine state. Phase is empty while the table is still in its lobby.
	Phase            engine.Phase
	HandIndex        int
	Dealer           int
	Turn             *int
	TrickNumber      int
	AwaitingTrickClr bool
	LastTrickWinner  *int
	Trick            []engine.TrickPlay
	Bids             [4]*int
	TricksWon        [4]int
	Totals           [4]float64
	RoundScores      [4][]float64
	HandCounts       [4]int
	// Hands holds every seat's remaining cards, ids only. An admin may see
	// what a player holds; that is the point of the dashboard.
	Hands    [4][]string
	Rankings []engine.SeatRanking

	// Pending clocks, in unix milliseconds of the server clock. Zero means the
	// clock is not running. Kind names what the auto deadline will do.
	TurnClock    Deadline
	CountdownAt  time.Time
	HandAdvance  time.Time
	IdleCollect  time.Time
	Seats        [4]SeatStatus
	Pacing       Pacing
	FillWait     time.Duration
	MinPlayers   int
	HumanSeats   int
	ConnectedHum int
}

// Deadline is a scheduled auto action.
type Deadline struct {
	At   time.Time
	Kind string // "none" | "clearTrick" | "serverMove" | "turnTimeout"
	Seat int    // seat a serverMove/turnTimeout applies to; -1 otherwise
}

// SeatStatus is one seat's full description, for an admin who needs more than
// the engine's PlayerInfo redaction — player identity, grace windows, host.
type SeatStatus struct {
	Seat       int
	Occupied   bool
	Name       string
	Kind       engine.PlayerKind
	Difficulty engine.Difficulty
	Connected  bool
	Autoplay   bool
	Confirmed  bool
	Player     auth.GuestID
	UserID     string
	Host       bool
	GraceUntil time.Time
}

// buildStatus runs on the actor goroutine, so it reads live state without a
// lock. It is attached here (rather than inlined in handle) to keep the
// dispatch switch small.
func (r *Room) buildStatus() Status {
	s := Status{
		ID:           r.id,
		Mode:         r.mode,
		Accepting:    r.accepting.Load(),
		Started:      r.started,
		StartedAt:    r.startedAt,
		LastActive:   r.lastActivity,
		TotalHands:   r.totalHands,
		HostSeat:     r.hostSeat,
		IdleCollect:  r.idleAt,
		CountdownAt:  r.countdownAt,
		HandAdvance:  r.handAdvanceAt,
		Pacing:       r.pacing,
		FillWait:     r.fillWait(),
		MinPlayers:   r.MinPlayers(),
		HumanSeats:   r.occupiedHumanSeats(),
		ConnectedHum: r.connectedHumans(),
		TurnClock: Deadline{
			At:   r.autoAt,
			Kind: "none",
			Seat: -1,
		},
	}

	switch r.autoKind {
	case autoClearTrick:
		s.TurnClock.Kind = "clearTrick"
	case autoServerMove:
		s.TurnClock.Kind = "serverMove"
	case autoTurnTimeout:
		s.TurnClock.Kind = "turnTimeout"
	}
	if s.TurnClock.Kind != "none" {
		s.TurnClock.Seat = r.autoSeat
	} else {
		s.TurnClock.At = time.Time{}
	}

	for i := range r.seats {
		seat := &r.seats[i]
		s.Seats[i] = SeatStatus{
			Seat:       i,
			Occupied:   seat.occupied,
			Name:       seat.name,
			Kind:       seat.kind,
			Difficulty: seat.difficulty,
			Connected:  seat.connected,
			Autoplay:   seat.autoplay,
			Confirmed:  seat.confirmed,
			Player:     seat.player,
			UserID:     seat.userID,
			Host:       i == r.hostSeat,
			GraceUntil: seat.graceUntil,
		}
	}

	if !r.started || r.game == nil {
		return s
	}
	g := r.game
	s.Phase = g.Phase
	s.HandIndex = g.HandIndex
	s.Dealer = g.Dealer
	if g.Turn != nil {
		t := *g.Turn
		s.Turn = &t
	}
	s.TrickNumber = g.TrickNumber
	s.AwaitingTrickClr = g.AwaitingTrickClr
	s.Trick = append([]engine.TrickPlay{}, g.Trick...)
	s.Bids = g.Bids
	s.TricksWon = g.TricksWon
	s.Totals = g.Totals
	for i := 0; i < 4; i++ {
		hand := g.HandOf(i)
		s.HandCounts[i] = len(hand)
		s.Hands[i] = cardIDs(hand)
		s.RoundScores[i] = append([]float64{}, g.RoundScores[i]...)
	}
	s.Rankings = append([]engine.SeatRanking{}, g.Rankings...)
	if g.LastTrick != nil {
		winner := g.LastTrick.Winner
		s.LastTrickWinner = &winner
	}
	return s
}

// cardIDs renders a hand the way the wire already spells cards.
func cardIDs(hand []engine.Card) []string {
	if hand == nil {
		return []string{}
	}
	out := make([]string, len(hand))
	for i, c := range hand {
		out[i] = c.ID()
	}
	return out
}
