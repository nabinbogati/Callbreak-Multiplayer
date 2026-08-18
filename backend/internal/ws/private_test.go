package ws

import (
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

func TestPrivateTableTwoHumansPlayAFullGame(t *testing.T) {
	s := newStack(t)

	host := s.dial("Nabin")
	host.join("7QF2", map[string]any{"create": true})
	joined := host.awaitType(2*time.Second, protocol.TypeJoined)
	if joined.num("seat") != 0 {
		t.Fatalf("the room's creator took seat %d, want 0", joined.num("seat"))
	}
	if !joined.boolean("isHost") {
		t.Fatal("the room's creator must be the host")
	}
	host.awaitType(2*time.Second, protocol.TypeLobby)

	guest := s.dial("Riya")
	guest.join("7QF2", nil)
	guestJoined := guest.awaitType(2*time.Second, protocol.TypeJoined)
	if guestJoined.num("seat") != 1 {
		t.Fatalf("the second player took seat %d, want 1", guestJoined.num("seat"))
	}
	if guestJoined.boolean("isHost") {
		t.Fatal("a joining player must not be the host")
	}

	// The host sees the guest arrive before anything is dealt.
	lobby := host.await(2*time.Second, "a lobby listing both players", func(f frame) bool {
		return f.Type == protocol.TypeLobby && len(f.Raw["seats"]) > 0 && f.boolean("canStart") &&
			countSeats(t, f) == 2
	})
	if lobby.num("hostSeat") != 0 {
		t.Fatalf("hostSeat = %d, want 0", lobby.num("hostSeat"))
	}

	// A guest cannot start the game.
	guest.send(map[string]any{"type": protocol.TypeStart})
	notHost := guest.awaitType(2*time.Second, protocol.TypeError)
	if notHost.str("code") != protocol.ErrNotHost {
		t.Fatalf("guest start rejected with %q, want %q", notHost.str("code"), protocol.ErrNotHost)
	}
	host.expectNo(200*time.Millisecond, "a view before the host started", func(f frame) bool {
		return f.Type == protocol.TypeView
	})

	host.send(map[string]any{"type": protocol.TypeStart})

	done := make(chan *engine.View, 2)
	go func() { done <- guest.drive(20 * time.Second) }()
	final := host.drive(20 * time.Second)
	guestFinal := <-done

	for name, view := range map[string]*engine.View{"host": final, "guest": guestFinal} {
		if view.Phase != engine.PhaseGameOver {
			t.Fatalf("%s ended in phase %q", name, view.Phase)
		}
		if len(view.Rankings) != 4 {
			t.Fatalf("%s saw %d rankings, want 4", name, len(view.Rankings))
		}
		if view.HandIndex != engine.HandsPerGame-1 {
			t.Fatalf("%s finished on hand %d, want %d", name, view.HandIndex, engine.HandsPerGame-1)
		}
		for seat := 0; seat < 4; seat++ {
			if got := len(view.RoundScores[seat]); got != engine.HandsPerGame {
				t.Fatalf("%s: seat %d has %d round scores, want %d",
					name, seat, got, engine.HandsPerGame)
			}
		}
	}

	// Both players must agree on the outcome — the whole point of one
	// authoritative engine.
	for seat := 0; seat < 4; seat++ {
		if final.Totals[seat] != guestFinal.Totals[seat] {
			t.Fatalf("seat %d: host saw %v, guest saw %v",
				seat, final.Totals[seat], guestFinal.Totals[seat])
		}
	}

	// Every client — including the guest, who only ever saw views — must be
	// able to tell who the host is, right down to the final frame.
	for name, view := range map[string]*engine.View{"host": final, "guest": guestFinal} {
		if view.HostSeat == nil || *view.HostSeat != 0 {
			t.Fatalf("%s: view names host seat %v, want 0", name, view.HostSeat)
		}
	}

	// The two empty seats were filled with bots, using the same names the
	// offline game uses.
	bots := 0
	for _, p := range final.Players {
		if p.Kind == engine.KindBot {
			bots++
			if p.Name != room.BotNames[0] && p.Name != room.BotNames[1] && p.Name != room.BotNames[2] {
				t.Fatalf("unexpected bot name %q", p.Name)
			}
		}
	}
	if bots != 2 {
		t.Fatalf("table had %d bots, want 2", bots)
	}
}

func TestPrivateOnlyTheHostSeesStart(t *testing.T) {
	s := newStack(t)

	host := s.dial("Nabin")
	host.join("7QF2", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)

	guest := s.dial("Riya")
	guest.join("7QF2", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	// The guest's own lobby must not offer Start — only the host may deal,
	// and showing a button that the server then rejects just invites a
	// confusing press.
	guestLobby := guest.awaitType(2*time.Second, protocol.TypeLobby)
	if guestLobby.boolean("canStart") {
		t.Fatal("a private guest must not be able to start the game")
	}
	if guestLobby.boolean("isHost") {
		t.Fatal("a joining player must not be the host")
	}

	// The host still gets the button — once a partner is in the room.
	host.await(2*time.Second, "the host's startable lobby", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.boolean("canStart")
	})
}

func countSeats(t *testing.T, f frame) int {
	t.Helper()
	var seats []map[string]any
	if err := decodeInto(f.Raw["seats"], &seats); err != nil {
		t.Fatalf("decode seats: %v", err)
	}
	return len(seats)
}

func TestPrivateTableNeedsTwoHumansToStart(t *testing.T) {
	s := newStack(t)

	host := s.dial("Nabin")
	host.join("2HUM", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)

	lobby := host.awaitType(2*time.Second, protocol.TypeLobby)
	if lobby.boolean("canStart") {
		t.Fatal("a solo host must not be offered Start")
	}

	// A premature Start press is refused, not honoured.
	host.send(map[string]any{"type": protocol.TypeStart})
	err := host.awaitType(2*time.Second, protocol.TypeError)
	if err.str("code") != protocol.ErrRoomNotReady {
		t.Fatalf("solo start rejected with %q, want %q", err.str("code"), protocol.ErrRoomNotReady)
	}

	// Once a second human sits down, the button and the deal work.
	partner := s.dial("Riya")
	partner.join("2HUM", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)

	host.await(2*time.Second, "the host's startable lobby", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.boolean("canStart")
	})
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)
}

func TestPrivateRoomRejectsAFifthPlayer(t *testing.T) {
	s := newStack(t)

	for i := 0; i < 4; i++ {
		c := s.dial("player")
		c.join("ABCD", map[string]any{"create": i == 0})
		c.awaitType(2*time.Second, protocol.TypeJoined)
	}

	fifth := s.dial("late")
	fifth.join("ABCD", nil)
	err := fifth.awaitType(2*time.Second, protocol.TypeError)
	if err.str("code") != protocol.ErrRoomFull {
		t.Fatalf("fifth player got %q, want %q", err.str("code"), protocol.ErrRoomFull)
	}
	if !err.boolean("fatal") {
		t.Error("a full room is fatal for that connection")
	}
}

func TestJoiningAfterTheDealIsRejected(t *testing.T) {
	s := newStack(t)

	host := s.dial("host")
	host.join("BCDE", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("BCDE", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	late := s.dial("late")
	late.join("BCDE", nil)
	err := late.awaitType(2*time.Second, protocol.TypeError)
	if err.str("code") != protocol.ErrGameStarted {
		t.Fatalf("late joiner got %q, want %q", err.str("code"), protocol.ErrGameStarted)
	}
}

func TestIllegalMovesAreRejectedWithoutChangingState(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		// Stop the bots from moving so the test can inspect a stable table.
		p.BotThinkMin = 30 * time.Second
		p.BidTimeout = 30 * time.Second
	})

	host := s.dial("host")
	host.join("CDEF", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("CDEF", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})

	// Seat 0 deals, so seat 1 — the human partner, who is idle — bids first,
	// and it is not the host's turn.
	view := host.awaitType(2*time.Second, protocol.TypeView)
	_ = view

	host.send(map[string]any{"type": protocol.TypeBid, "bid": 5})
	rejected := host.awaitType(2*time.Second, protocol.TypeError)
	if rejected.str("code") != protocol.ErrNotYourTurn {
		t.Fatalf("out-of-turn bid rejected with %q, want %q",
			rejected.str("code"), protocol.ErrNotYourTurn)
	}

	// The server resends the authoritative view so a confused client resyncs,
	// and nothing about the table changed.
	resync := host.awaitType(2*time.Second, protocol.TypeView)
	var after engine.View
	if err := decodeInto(resync.Data, &after); err != nil {
		t.Fatal(err)
	}
	if after.Bids[0] != nil {
		t.Fatal("a rejected bid was recorded anyway")
	}
	if after.Phase != engine.PhaseBidding {
		t.Fatalf("phase moved to %q after a rejected bid", after.Phase)
	}
}

func TestMalformedFramesDoNotKillTheConnection(t *testing.T) {
	s := newStack(t)
	c := s.dial("prober")
	c.join("DEFG", map[string]any{"create": true})
	c.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("DEFG", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)

	for _, junk := range []string{
		`not json at all`,
		`{"type":"nonsense"}`,
		`{"type":"play"}`,
		`{"type":"play","card":"ZZ"}`,
		`{"type":"bid"}`,
		`[]`,
		`{"type":"join","room":""}`,
	} {
		c.sendRaw(junk)
		err := c.awaitType(2*time.Second, protocol.TypeError)
		if err.boolean("fatal") {
			t.Fatalf("junk frame %q was treated as fatal", junk)
		}
	}

	// Still alive and still able to play.
	c.send(map[string]any{"type": protocol.TypeStart})
	c.awaitType(2*time.Second, protocol.TypeView)
}

func TestPlayingBeforeJoiningIsRefused(t *testing.T) {
	s := newStack(t)
	c := s.dial("stranger")
	c.send(map[string]any{"type": protocol.TypeBid, "bid": 3})
	err := c.awaitType(2*time.Second, protocol.TypeError)
	if err.str("code") != protocol.ErrUnauthorized {
		t.Fatalf("got %q, want %q", err.str("code"), protocol.ErrUnauthorized)
	}
}

func TestJoiningARoomThatDoesNotExistIsRefused(t *testing.T) {
	s := newStack(t)

	// A join without the create flag must not mint a brand-new room: a
	// mistyped or stale code is an error, not an invitation to spawn an empty
	// table nobody can find.
	c := s.dial("Nabin")
	c.join("9XYZ", nil)
	err := c.awaitType(2*time.Second, protocol.TypeError)
	if err.str("code") != protocol.ErrRoomNotFound {
		t.Fatalf("join to a missing room got %q, want %q", err.str("code"), protocol.ErrRoomNotFound)
	}

	// The code is still free afterwards: creating it for real works, and a
	// plain join then finds it.
	creator := s.dial("host")
	creator.join("9XYZ", map[string]any{"create": true})
	creator.awaitType(2*time.Second, protocol.TypeJoined)

	joiner := s.dial("guest")
	joiner.join("9XYZ", nil)
	joined := joiner.awaitType(2*time.Second, protocol.TypeJoined)
	if joined.boolean("isHost") {
		t.Fatal("a plain joiner must not be made the host")
	}
}

// TestPrivateRestartDealsTheGuestAFreshHand0 proves that after a full game a
// private host's restart hands the connected guest a brand-new bidding view on
// hand 0 with a clean slate — the exact frame the client's dealing flourish
// fires on. A guest pressing "play again" is refused; only the host may reset.
func TestPrivateRestartDealsTheGuestAFreshHand0(t *testing.T) {
	s := newStack(t)

	host := s.dial("Nabin")
	host.join("7QF2", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)

	guest := s.dial("Riya")
	guest.join("7QF2", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	// A guest cannot restart — the same rule as starting.
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	done := make(chan *engine.View, 1)
	go func() { done <- guest.drive(40 * time.Second) }()
	host.drive(40 * time.Second)
	guestFinal := <-done
	if guestFinal.Phase != engine.PhaseGameOver {
		t.Fatalf("guest ended in phase %q, want gameOver", guestFinal.Phase)
	}
	if guestFinal.HandIndex != engine.HandsPerGame-1 {
		t.Fatalf("guest finished on hand %d, want %d", guestFinal.HandIndex, engine.HandsPerGame-1)
	}

	// Before the restart no more gameplay views may arrive — the table sits on
	// the scoreboard. Anything bidding/playing here would be a spurious re-deal
	// that could poison the client's "already dealt this hand" guard.
	guest.expectNo(200*time.Millisecond, "a fresh deal before the restart", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Phase == engine.PhaseBidding || v.Phase == engine.PhasePlaying
	})

	// The guest must not be able to reset the table either.
	guest.send(map[string]any{"type": protocol.TypeRestart})
	notHost := guest.awaitType(2*time.Second, protocol.TypeError)
	if notHost.str("code") != protocol.ErrNotHost {
		t.Fatalf("guest restart rejected with %q, want %q", notHost.str("code"), protocol.ErrNotHost)
	}

	// The host restarts; the guest must then see a brand-new hand 0, bidding.
	host.send(map[string]any{"type": protocol.TypeRestart})
	var fresh engine.View
	guest.await(3*time.Second, "the guest's freshly dealt game", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		if err := decodeInto(f.Data, &fresh); err != nil {
			return false
		}
		return fresh.HandIndex == 0 && fresh.Phase == engine.PhaseBidding
	})
	for seat := 0; seat < 4; seat++ {
		if fresh.Totals[seat] != 0 {
			t.Fatalf("restart kept seat %d's total at %v", seat, fresh.Totals[seat])
		}
		if len(fresh.RoundScores[seat]) != 0 {
			t.Fatalf("restart kept seat %d's round history", seat)
		}
	}
}
