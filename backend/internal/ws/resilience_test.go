package ws

import (
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// startedPrivateTable seats two humans in a private room — it takes at least
// two to deal — and kicks off the game. Only the host (seat 0) is returned;
// the partner is a quiet socket that is autoplayed by the server.
func startedPrivateTable(t *testing.T, s *testStack, code string) *testClient {
	t.Helper()
	host := s.dial("host")
	host.join(code, map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	guest := s.dial("guest")
	guest.join(code, nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)
	return host
}

func TestTurnTimeoutIsPlayedByTheServer(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 150 * time.Millisecond
		p.PlayTimeouts = room.FlatPlayTimeouts(150 * time.Millisecond)
	})

	host := startedPrivateTable(t, s, "TYME")

	// The human never acts. The table must still reach the playing phase,
	// because the server bids on their behalf when the clock runs out.
	host.await(5*time.Second, "the server to bid for an idle player", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Bids[0] != nil
	})

	// And the whole game finishes without the player touching anything.
	host.await(30*time.Second, "the game to play itself out", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.Phase == engine.PhaseHandOver {
			// Nobody consents, so only the hand-advance timeout moves this on.
			return false
		}
		return v.Phase == engine.PhaseGameOver
	})
}

func TestHumanTurnsCarryADeadlineAndBotTurnsDoNot(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 5 * time.Second
		p.BotThinkMin = 40 * time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("host")
	host.join("DEAD", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	guest := s.dial("guest")
	guest.join("DEAD", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	// Seat 1 is the human guest, and it bids before the dealer at seat 0. An
	// idle partner would park the auction on its 5s clock, so it plays its one
	// bid eagerly — only the host's own turn is under examination here.
	go func() {
		for f := range guest.frames {
			if f.Type != protocol.TypeView {
				continue
			}
			v := guest.currentView()
			if v == nil {
				continue
			}
			if v.Phase == engine.PhaseBidding && v.Turn != nil && *v.Turn == 1 && v.Bids[1] == nil {
				guest.send(map[string]any{"type": protocol.TypeBid, "bid": engine.SuggestBid(v.Hand)})
				return
			}
		}
	}()

	var sawBotTurn bool
	host.await(5*time.Second, "the human's turn to carry a deadline", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.Turn == nil {
			return false
		}
		if *v.Turn != 0 {
			// A bot is on the clock: the client must not be shown a countdown
			// for a seat the player cannot influence.
			if v.TurnDeadlineMs != 0 {
				t.Fatalf("a bot turn carried a deadline of %d", v.TurnDeadlineMs)
			}
			sawBotTurn = true
			return false
		}
		if v.TurnDeadlineMs <= v.ServerTimeMs {
			t.Fatalf("human turn deadline %d is not in the future of server time %d",
				v.TurnDeadlineMs, v.ServerTimeMs)
		}
		return true
	})

	if !sawBotTurn {
		t.Error("the test never observed a bot on the clock, so it proved only half of what it claims")
	}
}

func TestDroppedPlayerIsCoveredByABotAndCanReclaimTheSeat(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.ReconnectGrace = 10 * time.Second
		p.BidTimeout = 10 * time.Second
		p.PlayTimeouts = room.FlatPlayTimeouts(10 * time.Second)
	})

	// Two humans, so the table survives one of them vanishing.
	host := s.dial("host")
	host.join("DRPS", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)

	guest := s.dial("guest")
	guest.join("DRPS", nil)
	guestJoined := guest.awaitType(2*time.Second, protocol.TypeJoined)
	guestSeat := guestJoined.num("seat")
	guestGuest, guestResume := guest.tokens()

	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	// The guest's phone loses signal.
	guest.close()

	host.await(5*time.Second, "the dropped seat to be reported disconnected", func(f frame) bool {
		return f.Type == protocol.TypeEvent &&
			f.str("event") == protocol.EventSeatChange &&
			f.num("seat") == guestSeat &&
			!f.boolean("connected")
	})

	// A bot covers the seat, so the table keeps moving rather than stalling on
	// a player who is not there.
	host.await(10*time.Second, "the table to keep playing without the dropped seat", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.Players[guestSeat].Connected {
			return false
		}
		return v.Bids[guestSeat] != nil
	})

	// They come back within the grace window and take their seat again.
	back := s.dial("guest")
	back.join("DRPS", map[string]any{
		"guestToken":  guestGuest,
		"resumeToken": guestResume,
	})
	rejoined := back.awaitType(5*time.Second, protocol.TypeJoined)
	if rejoined.num("seat") != guestSeat {
		t.Fatalf("reconnected into seat %d, want %d", rejoined.num("seat"), guestSeat)
	}
	if !rejoined.boolean("reconnected") {
		t.Error("a reclaimed seat must be flagged as a reconnection")
	}
	if rejoined.str("playerId") == "" {
		t.Error("a reconnecting player must keep an identity")
	}

	// The returning player is dealt back into the game they left, with their
	// own cards and score history intact.
	view := back.awaitType(5*time.Second, protocol.TypeView)
	var v engine.View
	if err := decodeInto(view.Data, &v); err != nil {
		t.Fatal(err)
	}
	if v.You == nil || *v.You != guestSeat {
		t.Fatalf("the resumed view belongs to seat %v, want %d", v.You, guestSeat)
	}
	if !v.Players[guestSeat].Connected {
		t.Error("the reclaimed seat is still marked disconnected")
	}
	if v.Players[guestSeat].Kind != engine.KindHuman {
		t.Error("the reclaimed seat is still marked as a bot")
	}
}

// TestQuickplayPlayerCanReclaimTheirSeatAfterADrop is the quickplay analogue of
// TestDroppedPlayerIsCoveredByABotAndCanReclaimTheSeat. Quickplay joins only say
// QUICKPLAY, never the table's generated code, so the resume token is the only
// thing that can name the table a player dropped from — without it, a
// reconnecting "vs Humans" player is dealt into a brand-new match instead of the
// one they were mid-way through.
func TestQuickplayPlayerCanReclaimTheirSeatAfterADrop(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, p *room.Pacing) {
		// One human is enough to deal, so the test needs no crowd.
		cfg.MatchMinPlayers = 1
		cfg.MatchFillWait = 50 * time.Millisecond
		// Long enough that the seat is still being held when the player returns.
		p.ReconnectGrace = 10 * time.Second
		p.BidTimeout = 10 * time.Second
		p.PlayTimeouts = room.FlatPlayTimeouts(10 * time.Second)
	})

	player := s.dial("player")
	joinQuickplay(player)
	joined := player.awaitType(2*time.Second, protocol.TypeJoined)
	seat := joined.num("seat")
	roomCode := joined.str("room")
	guestGuest, guestResume := player.tokens()

	player.await(3*time.Second, "the table to deal", func(f frame) bool {
		return f.Type == protocol.TypeView
	})

	// The phone loses signal mid-game.
	player.close()

	// They come back within the grace window, presenting the same credentials
	// through the same QUICKPLAY join as before.
	back := s.dial("player")
	back.join(protocol.QuickplayRoom, map[string]any{
		"mode":        string(protocol.ModeOnline),
		"guestToken":  guestGuest,
		"resumeToken": guestResume,
	})
	rejoined := back.awaitType(5*time.Second, protocol.TypeJoined)
	if rejoined.str("room") != roomCode {
		t.Fatalf("reconnected into room %q, want %q", rejoined.str("room"), roomCode)
	}
	if rejoined.num("seat") != seat {
		t.Fatalf("reconnected into seat %d, want %d", rejoined.num("seat"), seat)
	}
	if !rejoined.boolean("reconnected") {
		t.Error("a reclaimed quickplay seat must be flagged as a reconnection")
	}

	// They are dealt back into the match they were in, not parked in a lobby.
	view := back.awaitType(5*time.Second, protocol.TypeView)
	var v engine.View
	if err := decodeInto(view.Data, &v); err != nil {
		t.Fatal(err)
	}
	if v.You == nil || *v.You != seat {
		t.Fatalf("the resumed view belongs to seat %v, want %d", v.You, seat)
	}
	if !v.Players[seat].Connected {
		t.Error("the reclaimed seat is still marked disconnected")
	}
}

// TestQuickplayReconnectDeliversTheFullCurrentState goes one step past the seat
// reclaim: a reconnecting player must be handed the whole table's live state —
// their cards, every seat's info and score history, and the current turn — not
// just told which seat they are. The resumed view is the same snapshot any
// seated player gets, and the seat stays a living one the server keeps
// accepting input from.
func TestQuickplayReconnectDeliversTheFullCurrentState(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, p *room.Pacing) {
		// One human is enough to deal, so the test needs no crowd. Long clocks
		// so nothing advances out from under the assertions.
		cfg.MatchMinPlayers = 1
		cfg.MatchFillWait = 50 * time.Millisecond
		p.ReconnectGrace = 10 * time.Second
		p.BidTimeout = 10 * time.Second
		p.PlayTimeouts = room.FlatPlayTimeouts(10 * time.Second)
	})

	player := s.dial("player")
	joinQuickplay(player)
	joined := player.awaitType(2*time.Second, protocol.TypeJoined)
	seat := joined.num("seat")
	guestGuest, guestResume := player.tokens()

	dealt := player.await(3*time.Second, "the table to deal", func(f frame) bool {
		return f.Type == protocol.TypeView
	})
	var before engine.View
	if err := decodeInto(dealt.Data, &before); err != nil {
		t.Fatal(err)
	}
	if before.You == nil || *before.You != seat {
		t.Fatalf("dealt view is for seat %v, want %d", before.You, seat)
	}

	player.close()

	back := s.dial("player")
	back.join(protocol.QuickplayRoom, map[string]any{
		"mode":        string(protocol.ModeOnline),
		"guestToken":  guestGuest,
		"resumeToken": guestResume,
	})
	back.awaitType(5*time.Second, protocol.TypeJoined)

	// Reclaiming the seat is the start, not the whole job: the player must also
	// be handed the table's entire current state, in one authoritative view.
	resumed := back.await(5*time.Second, "a full resumed view", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.You != nil && *v.You == seat
	})
	var v engine.View
	if err := decodeInto(resumed.Data, &v); err != nil {
		t.Fatal(err)
	}

	// The whole table is present, not just a seat number.
	if len(v.Players) != 4 || len(v.HandCounts) != 4 {
		t.Fatalf("resumed view is not the full table: players=%d handCounts=%d",
			len(v.Players), len(v.HandCounts))
	}
	if v.You == nil || len(v.Hand) != v.HandCounts[*v.You] {
		t.Fatalf("resumed view carries %d cards; handCounts says %v",
			len(v.Hand), v.HandCounts)
	}

	// The seat is theirs again, as a person, not the bot that covered it.
	if !v.Players[seat].Connected {
		t.Error("the reclaimed seat is still marked disconnected")
	}
	if v.Players[seat].Kind != engine.KindHuman {
		t.Error("the reclaimed seat is still marked as a bot")
	}

	// The snapshot is live, not a replay of the one the player left with.
	if v.ServerTimeMs < before.ServerTimeMs {
		t.Errorf("resumed view (%d) is older than the pre-drop view (%d)",
			v.ServerTimeMs, before.ServerTimeMs)
	}

	// The seat is a living one: the server still accepts moves from it. If it
	// is the player's turn, place a legal bid and watch it land.
	if v.Phase == engine.PhaseBidding && v.Turn != nil && *v.Turn == seat {
		back.send(map[string]any{"type": protocol.TypeBid, "bid": engine.SuggestBid(v.Hand)})
		back.await(5*time.Second, "the reconnected player's bid to be counted", func(f frame) bool {
			if f.Type != protocol.TypeView {
				return false
			}
			var nv engine.View
			if err := decodeInto(f.Data, &nv); err != nil {
				return false
			}
			return nv.Bids[seat] != nil
		})
	} else {
		back.send(map[string]any{"type": protocol.TypeAwake})
	}
	back.expectNo(500*time.Millisecond, "a rejection for a reclaimed seat", func(f frame) bool {
		return f.Type == protocol.TypeError && f.boolean("fatal")
	})
}

// TestReconnectBeforeTheOldSocketIsNoticed comes at the race from the other
// side: the game has advanced many frames since the server last heard from a
// phone, but the server only *discovers* the drop when a new socket from the
// same player shows up. The old socket must be displaced and turned into a
// bystander (any frame it sends after that must not reach the table), while the
// new one is elected the seat and handed the current state.
func TestReconnectBeforeTheOldSocketIsNoticed(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.ReconnectGrace = 10 * time.Second
		p.BidTimeout = 10 * time.Second
		p.PlayTimeouts = room.FlatPlayTimeouts(10 * time.Second)
	})

	host := s.dial("host")
	host.join("DSPL", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	guest := s.dial("guest")
	guest.join("DSPL", nil)
	guestJoined := guest.awaitType(2*time.Second, protocol.TypeJoined)
	gSeat := guestJoined.num("seat")
	guestGuest, guestResume := guest.tokens()

	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	// The guest reconnects without closing the first socket — a silent network
	// switch can look exactly like this, with the old socket still open in the
	// OS while the game moved on without it.
	back := s.dial("guest")
	back.join("DSPL", map[string]any{
		"guestToken":  guestGuest,
		"resumeToken": guestResume,
	})
	rejoined := back.awaitType(3*time.Second, protocol.TypeJoined)
	if rejoined.num("seat") != gSeat {
		t.Fatalf("reconnected into seat %d, want %d", rejoined.num("seat"), gSeat)
	}
	if !rejoined.boolean("reconnected") {
		t.Error("seat reclaim must be flagged as a reconnection")
	}
	back.awaitType(3*time.Second, protocol.TypeView)

	// The displaced socket is told in no uncertain terms that it lost the seat,
	// so a player staring at a dead screen knows to act — and, crucially, it
	// receives a *fatal* error, which stops its client from blindly reconnecting
	// and ping-ponging with the newcomer for this seat.
	guest.await(3*time.Second, "the displaced socket to be told its seat is gone", func(f frame) bool {
		return f.Type == protocol.TypeError && f.boolean("fatal")
	})

	// The new socket is fully live: its frames reach the connection layer and
	// are answered. Had the server still listened to the old socket instead,
	// this pong would never come. The displaced socket is closed, so anything it
	// now tries to send is dead on arrival and cannot influence the table.
	back.send(map[string]any{"type": protocol.TypePing})
	back.awaitType(2*time.Second, protocol.TypePong)
}

// TestARoomSurvivesWhileASeatIsStillInGrace pins down a reconnection edge that
// used to end in a lobby. The last *connected* human leaves mid-game while
// another player is dropped but still inside their grace window. The table has
// nobody left to watch it, but the graced player is still entitled to come
// back — closing the room would make their rejoin land in a brand-new table
// instead of the game they were mid-way through, which is exactly the
// "reconnection took me to the lobby" symptom.
func TestARoomSurvivesWhileASeatIsStillInGrace(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.ReconnectGrace = 10 * time.Second
		p.BidTimeout = 10 * time.Second
		p.PlayTimeouts = room.FlatPlayTimeouts(10 * time.Second)
	})

	host := s.dial("host")
	host.join("GRAC", map[string]any{"create": true})
	hostJoined := host.awaitType(2*time.Second, protocol.TypeJoined)
	tableCode := hostJoined.str("room")

	guest := s.dial("guest")
	guest.join("GRAC", nil)
	guestJoined := guest.awaitType(2*time.Second, protocol.TypeJoined)
	guestSeat := guestJoined.num("seat")
	guestGuest, guestResume := guest.tokens()

	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	// The guest's signal drops; their seat enters its grace window.
	guest.close()
	host.await(5*time.Second, "the dropped seat to be reported disconnected", func(f frame) bool {
		return f.Type == protocol.TypeEvent &&
			f.str("event") == protocol.EventSeatChange &&
			f.num("seat") == guestSeat &&
			!f.boolean("connected")
	})

	// The host quits — the last connected human — while the guest's seat is
	// still being held. That must not tear the table down.
	host.send(map[string]any{"type": protocol.TypeLeave})

	// Wait for the leave to be processed (the room's own socket closes, so the
	// host has no frame to observe it by). If the flawed "last human left"
	// closing wins, the hub forgets the table here despite the live grace
	// window, and the guest's rejoin below would land in a brand-new room.
	gone := false
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := s.hub.Get(tableCode); !ok {
			gone = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if gone {
		t.Fatal("the table was collected while the guest's seat was still in grace")
	}

	// The guest comes back within grace and must land on the *same* live table,
	// not a fresh lobby.
	back := s.dial("guest")
	back.join("GRAC", map[string]any{
		"guestToken":  guestGuest,
		"resumeToken": guestResume,
	})
	rejoined := back.awaitType(5*time.Second, protocol.TypeJoined)
	if rejoined.str("room") != tableCode {
		t.Fatalf("reconnected into table %q, want the original %q", rejoined.str("room"), tableCode)
	}
	if rejoined.num("seat") != guestSeat {
		t.Fatalf("reconnected into seat %d, want %d", rejoined.num("seat"), guestSeat)
	}
	if !rejoined.boolean("reconnected") {
		t.Error("a reclaimed seat must be flagged as a reconnection")
	}

	view := back.awaitType(5*time.Second, protocol.TypeView)
	var v engine.View
	if err := decodeInto(view.Data, &v); err != nil {
		t.Fatal(err)
	}
	if v.You == nil || *v.You != guestSeat {
		t.Fatalf("the resumed view belongs to seat %v, want %d", v.You, guestSeat)
	}
}

func TestAResumeTokenCannotStealSomeoneElsesSeat(t *testing.T) {
	s := newStack(t)

	victim := s.dial("victim")
	victim.join("SAFE", map[string]any{"create": true})
	victim.awaitType(2*time.Second, protocol.TypeJoined)
	_, victimResume := victim.tokens()

	// A different player presents the victim's resume token. The token verifies
	// — it is genuinely signed — but it does not name them, so it must not seat
	// them anywhere except a fresh seat of their own.
	attacker := s.dial("attacker")
	attacker.join("SAFE", map[string]any{"resumeToken": victimResume})
	joined := attacker.awaitType(2*time.Second, protocol.TypeJoined)
	if joined.num("seat") == 0 {
		t.Fatal("a stolen resume token took over the victim's seat")
	}

	// The victim is untouched and still connected.
	victim.expectNo(300*time.Millisecond, "an eviction", func(f frame) bool {
		return f.Type == protocol.TypeError && f.boolean("fatal")
	})
}

func TestNextHandWaitsForEveryConnectedHuman(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		// Long enough that only genuine consent can advance the hand.
		p.HandAdvanceWait = 10 * time.Second
	})

	host := s.dial("host")
	host.join("WATS", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	guest := s.dial("guest")
	guest.join("WATS", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	host.send(map[string]any{"type": protocol.TypeStart})

	done := make(chan struct{})
	go func() { guest.driveUntilHandOver(30 * time.Second); close(done) }()
	host.driveUntilHandOver(30 * time.Second)
	<-done

	// One player is ready; the other is still reading the scoreboard.
	host.send(map[string]any{"type": protocol.TypeNext})
	ready := guest.await(3*time.Second, "a readyState frame", func(f frame) bool {
		return f.Type == protocol.TypeEvent && f.str("event") == protocol.EventReadyState
	})
	if ready.num("ready") != 1 || ready.num("total") != 2 {
		t.Fatalf("readyState = %d/%d, want 1/2", ready.num("ready"), ready.num("total"))
	}
	guest.expectNo(500*time.Millisecond, "the next hand being dealt without consent", func(f frame) bool {
		return f.Type == protocol.TypeEvent && f.str("event") == "handStart"
	})

	guest.send(map[string]any{"type": protocol.TypeNext})
	guest.await(3*time.Second, "the next hand", func(f frame) bool {
		return f.Type == protocol.TypeEvent && f.str("event") == "handStart"
	})
}

func TestNextHandGivesUpWaitingOnAStraggler(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.HandAdvanceWait = 200 * time.Millisecond
	})

	host := s.dial("host")
	host.join("STAL", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	guest := s.dial("guest")
	guest.join("STAL", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	host.send(map[string]any{"type": protocol.TypeStart})

	done := make(chan struct{})
	go func() { guest.driveUntilHandOver(30 * time.Second); close(done) }()
	host.driveUntilHandOver(30 * time.Second)
	<-done

	// Neither player consents. The table must not sit on the scoreboard forever.
	host.await(5*time.Second, "the hand to advance on its own", func(f frame) bool {
		return f.Type == protocol.TypeEvent && f.str("event") == "handStart"
	})
}

func TestAnEmptyTableIsCollected(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.IdleTTL = 200 * time.Millisecond
	})

	c := s.dial("brief")
	c.join("GNEX", map[string]any{"create": true})
	c.awaitType(2*time.Second, protocol.TypeJoined)
	if _, ok := s.hub.Get("GNEX"); !ok {
		t.Fatal("the table was not registered")
	}

	c.close()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := s.hub.Get("GNEX"); !ok {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("an abandoned table was never collected")
}

func TestAnEmptyPrivateLobbyClosesWhenEveryoneLeaves(t *testing.T) {
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		// A long idle TTL proves the close comes from the leaves themselves,
		// not from idle collection.
		p.IdleTTL = time.Hour
	})

	host := s.dial("host")
	host.join("LVLT", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	guest := s.dial("guest")
	guest.join("LVLT", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	if _, ok := s.hub.Get("LVLT"); !ok {
		t.Fatal("the table was not registered")
	}

	// Everybody leaves the lobby deliberately.
	host.send(map[string]any{"type": protocol.TypeLeave})
	guest.send(map[string]any{"type": protocol.TypeLeave})

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := s.hub.Get("LVLT"); !ok {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("an empty private lobby was not closed when everyone left")
}
