package ws

import (
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// awaitAutoplay waits for the server to announce a seat entering or leaving
// autoplay.
func awaitAutoplay(t *testing.T, c *testClient, seat int, on bool, d time.Duration) {
	t.Helper()
	c.await(d, "an autoplay announcement", func(f frame) bool {
		return f.Type == protocol.TypeEvent &&
			f.str("event") == protocol.EventAutoplay &&
			f.num("seat") == seat &&
			f.boolean("autoplay") == on
	})
}

func TestBidTimeoutDoesNotHandSeatToAutoplay(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 200 * time.Millisecond
		p.PlayTimeouts = room.FlatPlayTimeouts(10 * time.Second)
		p.BotThinkMin = time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("Idle")
	host.join("BRDS", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("BRDS", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	// Wait the bid clock out: the seat is bid for, but not handed over, because
	// bidding and play run independent clocks. Play goes on, the bid is set for
	// the idle seat, and the seat is not on autoplay.
	host.await(5*time.Second, "the hand to settle the missed bid and deal on", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Phase == engine.PhasePlaying && v.Bids[0] != nil && !v.Players[0].Autoplay
	})
}

func TestIdlePlayerIsHandedToAutoplayAndKeepsPlaying(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 200 * time.Millisecond
		p.PlayTimeouts = room.FlatPlayTimeouts(200 * time.Millisecond)
		// Slow bots, so a hand only progresses this fast if the idle seat has
		// genuinely stopped waiting out a full clock every turn.
		p.BotThinkMin = time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("Idle")
	host.join("AUTQ", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("AUTQ", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	// The player never acts. The bid deadline settles their bid but keeps the
	// seat; it is the play timeout that takes it over.
	awaitAutoplay(t, host, 0, true, 6*time.Second)

	host.await(3*time.Second, "the view to report the seat on autoplay", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Players[0].Autoplay
	})

	// The decisive property: from here the seat plays at bot speed. If autoplay
	// were per-turn, every one of this seat's turns would burn a fresh 200ms
	// clock and a whole hand could not finish this quickly.
	start := time.Now()
	host.await(6*time.Second, "the hand to play itself out", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Phase == engine.PhaseHandOver || v.HandIndex > 0
	})
	if elapsed := time.Since(start); elapsed > 4*time.Second {
		t.Fatalf("the hand took %s, which suggests each turn still waited out its clock", elapsed)
	}
}

func TestTappingTheTableTakesTheSeatBackFromAutoplay(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 150 * time.Millisecond
		// A real but short play clock: long enough that once the player is
		// back, their turn carries a deadline rather than a bot move, short
		// enough that an idle seat reaches autoplay promptly.
		p.PlayTimeouts = room.FlatPlayTimeouts(500 * time.Millisecond)
		p.BotThinkMin = 5 * time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("Returning")
	host.join("BACK", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("BACK", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	awaitAutoplay(t, host, 0, true, 3*time.Second)

	// The player taps the table. Not a move — just a sign of life.
	host.send(map[string]any{"type": protocol.TypeAwake})

	awaitAutoplay(t, host, 0, false, 3*time.Second)
	host.await(3*time.Second, "the view to report the seat back under control", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return !v.Players[0].Autoplay
	})

	// And the table now waits for them again: their turn carries a real
	// deadline rather than being played out from under them.
	host.await(5*time.Second, "the player's own turn to come back with a clock", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Turn != nil && *v.Turn == 0 && v.TurnDeadlineMs > v.ServerTimeMs
	})
}

func TestMakingAMoveAlsoCancelsAutoplay(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 150 * time.Millisecond
		// Short enough that a seat that keeps ignoring the clock reaches
		// autoplay promptly.
		p.PlayTimeouts = room.FlatPlayTimeouts(time.Second)
		p.BotThinkMin = 5 * time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("Player")
	host.join("MVES", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("MVES", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)
	awaitAutoplay(t, host, 0, true, 3*time.Second)

	// Playing a card is proof of presence on its own; a player should not have
	// to tap twice to take their seat back.
	host.await(5*time.Second, "our own turn to play", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.Turn == nil || *v.Turn != 0 || len(v.LegalMoveIDs) == 0 {
			return false
		}
		host.send(map[string]any{"type": protocol.TypePlay, "card": v.LegalMoveIDs[0]})
		return true
	})

	awaitAutoplay(t, host, 0, false, 3*time.Second)
}

// TestFirstBidderGetsDealGrace checks that the very first bid of a hand has a
// clock of BidTimeout + DealGrace: the deadline is anchored when the deal view
// goes out, while the dealing animation is still on screen, and must not eat
// into the bid. Later bidders keep the plain BidTimeout.
func TestFirstBidderGetsDealGrace(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 2 * time.Second
		p.DealGrace = 400 * time.Millisecond
		p.PlayTimeouts = room.FlatPlayTimeouts(2 * time.Second)
		p.BotThinkMin = time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("Host")
	host.join("GRAC", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("GRAC", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)

	host.send(map[string]any{"type": protocol.TypeStart})

	// The deal hands the first bid to seat 1 (the partner, dealer is seat 0).
	// Its own view must carry a deadline BidTimeout + DealGrace out even though
	// the view has only just gone out.
	partner.await(2*time.Second, "the deal to carry the graced first-bid deadline", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Phase == engine.PhaseBidding &&
			v.Turn != nil && *v.Turn == 1 &&
			v.TurnDeadlineMs-v.ServerTimeMs >= 2400
	})
	partner.send(map[string]any{"type": protocol.TypeBid, "bid": engine.SuggestBid(partner.currentView().Hand)})

	// Once the first bid is in, the clock falls back to the plain BidTimeout
	// for the seats that follow under their own turn.
	host.await(5*time.Second, "the host's own bid to carry an ungraced deadline", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.Phase != engine.PhaseBidding || v.Turn == nil || *v.Turn != 0 {
			return false
		}
		delta := v.TurnDeadlineMs - v.ServerTimeMs
		return delta >= 1900 && delta < 2400
	})
}

func TestAutoplayClearsWhenANewGameIsDealt(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 150 * time.Millisecond
		p.PlayTimeouts = room.FlatPlayTimeouts(150 * time.Millisecond)
		p.BotThinkMin = time.Millisecond
		p.BotThinkExtra = time.Millisecond
		p.HandAdvanceWait = 100 * time.Millisecond
	})

	host := s.dial("Idle")
	host.join("FRSH", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("FRSH", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)
	awaitAutoplay(t, host, 0, true, 3*time.Second)

	// Let the whole game finish under autoplay, then ask for a rematch. A new
	// game should start everyone at the controls — carrying autoplay across
	// would mean a player who came back for a rematch never got to play it.
	host.await(30*time.Second, "the game to end", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Phase == engine.PhaseGameOver
	})

	host.send(map[string]any{"type": protocol.TypeRestart})
	host.await(5*time.Second, "a fresh game with the seat under control", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.HandIndex == 0 && v.Phase == engine.PhaseBidding && !v.Players[0].Autoplay
	})
}
