package ws

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

func joinQuickplay(c *testClient) {
	c.join(protocol.QuickplayRoom, map[string]any{"mode": string(protocol.ModeOnline)})
}

// joinQuickplayWithHands is joinQuickplay for a player who has picked a hand
// count explicitly — Quickplay (3) or Normal Play (5).
func joinQuickplayWithHands(c *testClient, handsPerGame int) {
	c.join(protocol.QuickplayRoom, map[string]any{
		"mode":         string(protocol.ModeOnline),
		"handsPerGame": handsPerGame,
	})
}

// lobbySeat is one row of a lobby frame, as a test reads it.
type lobbySeat struct {
	Seat      int    `json:"seat"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Connected bool   `json:"connected"`
	IsYou     bool   `json:"isYou"`
}

func lobbySeats(t *testing.T, f frame) []lobbySeat {
	t.Helper()
	var seats []lobbySeat
	if err := json.Unmarshal(f.Raw["seats"], &seats); err != nil {
		t.Fatalf("decode lobby seats: %v", err)
	}
	return seats
}

// awaitLobbyWith waits for a lobby frame listing exactly n humans.
func awaitLobbyWith(t *testing.T, c *testClient, n int, d time.Duration) frame {
	t.Helper()
	return c.await(d, fmt.Sprintf("a lobby with %d players", n), func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.num("humansSeated") == n
	})
}

// isCountdown reports a countdown event, either a live one or a retraction.
func isCountdown(f frame, cancelled bool) bool {
	return f.Type == protocol.TypeEvent &&
		f.str("event") == protocol.EventCountdown &&
		f.boolean("cancelled") == cancelled
}

func TestQuickplayLobbyShowsWhoElseIsWaiting(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		// Long enough that the table stays in its lobby while the test looks at it.
		cfg.MatchFillWait = 30 * time.Second
	})

	// A player waiting alone is already at a real table, and can see it.
	alice := s.dial("Alice")
	joinQuickplay(alice)
	joined := alice.awaitType(2*time.Second, protocol.TypeJoined)
	if joined.str("room") == "" {
		t.Fatal("a quickplay player must be told which table they are at")
	}

	solo := awaitLobbyWith(t, alice, 1, 2*time.Second)
	if solo.num("minPlayers") != 2 {
		t.Fatalf("minPlayers = %d, want 2", solo.num("minPlayers"))
	}
	seats := lobbySeats(t, solo)
	if len(seats) != 1 || seats[0].Name != "Alice" || !seats[0].IsYou {
		t.Fatalf("lobby did not describe the waiting player: %+v", seats)
	}

	// A second player joins the same table, and both see both names.
	bob := s.dial("Bob")
	joinQuickplay(bob)
	bob.awaitType(2*time.Second, protocol.TypeJoined)

	for _, c := range []*testClient{alice, bob} {
		lobby := awaitLobbyWith(t, c, 2, 3*time.Second)
		seats := lobbySeats(t, lobby)
		if len(seats) != 2 {
			t.Fatalf("%s sees %d seats, want 2", c.name, len(seats))
		}
		names := map[string]bool{}
		you := 0
		for _, seat := range seats {
			names[seat.Name] = true
			if seat.Kind != "human" {
				t.Fatalf("%s sees a bot in the pre-game lobby: %+v", c.name, seat)
			}
			if !seat.Connected {
				t.Fatalf("%s sees a disconnected seat: %+v", c.name, seat)
			}
			if seat.IsYou {
				you++
			}
		}
		if !names["Alice"] || !names["Bob"] {
			t.Fatalf("%s sees names %v, want both Alice and Bob", c.name, names)
		}
		if you != 1 {
			t.Fatalf("%s sees %d seats marked as themselves, want exactly 1", c.name, you)
		}
	}

	// Two is enough, so the table is now counting down.
	alice.await(3*time.Second, "a countdown", func(f frame) bool {
		return isCountdown(f, false)
	})
}

func TestQuickplayWillNotDealWithOnlyOnePlayer(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 100 * time.Millisecond
	})

	alice := s.dial("Alice")
	joinQuickplay(alice)
	alice.awaitType(2*time.Second, protocol.TypeJoined)

	// However long a lone player waits, the table must not deal three bots
	// against them — that is the offline game, not a match against people.
	alice.expectNo(time.Second, "a game dealt for a single player", func(f frame) bool {
		return f.Type == protocol.TypeView ||
			(f.Type == protocol.TypeEvent && f.str("event") == "handStart")
	})

	// The moment a second player arrives, it starts.
	bob := s.dial("Bob")
	joinQuickplay(bob)
	bob.awaitType(2*time.Second, protocol.TypeJoined)

	alice.await(5*time.Second, "the game to start once two are seated", func(f frame) bool {
		return f.Type == protocol.TypeView
	})
}

func TestLeavingTheLobbyDoesNotBreakItForEveryoneElse(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 30 * time.Second
	})

	alice, bob, carol := s.dial("Alice"), s.dial("Bob"), s.dial("Carol")
	for _, c := range []*testClient{alice, bob, carol} {
		joinQuickplay(c)
		c.awaitType(2*time.Second, protocol.TypeJoined)
	}
	awaitLobbyWith(t, alice, 3, 3*time.Second)

	// Carol changes her mind and leaves.
	carol.send(map[string]any{"type": protocol.TypeLeave})

	// The table carries on with two, and Carol is gone from it rather than
	// lingering as a ghost seat.
	lobby := awaitLobbyWith(t, alice, 2, 3*time.Second)
	for _, seat := range lobbySeats(t, lobby) {
		if seat.Name == "Carol" {
			t.Fatalf("a player who left is still listed: %+v", seat)
		}
	}

	// Two is still the minimum, so the pending start must survive her leaving.
	// Cancelling here would punish the players who stayed.
	alice.expectNo(500*time.Millisecond, "the start being called off", func(f frame) bool {
		return isCountdown(f, true)
	})
}

func TestLeavingAtTheLastMomentCancelsTheStart(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, p *room.Pacing) {
		// A long fill wait so the countdown is still running when Bob quits.
		cfg.MatchFillWait = 30 * time.Second
		p.StartCountdown = 30 * time.Second
	})

	alice, bob := s.dial("Alice"), s.dial("Bob")
	for _, c := range []*testClient{alice, bob} {
		joinQuickplay(c)
		c.awaitType(2*time.Second, protocol.TypeJoined)
	}
	awaitLobbyWith(t, alice, 2, 3*time.Second)
	alice.await(3*time.Second, "a countdown", func(f frame) bool {
		return isCountdown(f, false)
	})

	// Bob quits while the table is counting down. Alice must be told the start
	// is off rather than left watching a countdown for a game that is not coming.
	bob.send(map[string]any{"type": protocol.TypeLeave})

	var retracted, backToOne bool
	alice.await(3*time.Second, "the start to be called off", func(f frame) bool {
		if isCountdown(f, true) {
			retracted = true
		}
		if f.Type == protocol.TypeLobby && f.num("humansSeated") == 1 {
			if f.boolean("started") {
				t.Fatal("the table dealt despite dropping below the minimum")
			}
			backToOne = true
		}
		return retracted && backToOne
	})

	alice.expectNo(time.Second, "a game dealt after the last-moment quit", func(f frame) bool {
		return f.Type == protocol.TypeView
	})

	// And it recovers: a replacement player restarts the countdown.
	carol := s.dial("Carol")
	joinQuickplay(carol)
	carol.awaitType(2*time.Second, protocol.TypeJoined)
	awaitLobbyWith(t, alice, 2, 3*time.Second)
}

func TestDroppingOutOfTheLobbyIsTreatedAsLeaving(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 30 * time.Second
	})

	alice, bob := s.dial("Alice"), s.dial("Bob")
	for _, c := range []*testClient{alice, bob} {
		joinQuickplay(c)
		c.awaitType(2*time.Second, protocol.TypeJoined)
	}
	awaitLobbyWith(t, alice, 2, 3*time.Second)

	// A socket that simply dies before the deal must free the seat outright.
	// Holding it for the reconnect grace would strand everyone else behind a
	// player who is not coming back to a game that never started.
	bob.close()

	awaitLobbyWith(t, alice, 1, 3*time.Second)
	alice.expectNo(time.Second, "a game dealt for the one remaining player", func(f frame) bool {
		return f.Type == protocol.TypeView
	})
}

func TestQuickplayGathersPlayersAtOneTable(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 30 * time.Second
	})

	rooms := map[string]int{}
	clients := make([]*testClient, 4)
	for i := range clients {
		clients[i] = s.dial("player")
		joinQuickplay(clients[i])
		joined := clients[i].awaitType(2*time.Second, protocol.TypeJoined)
		rooms[joined.str("room")]++
		if joined.boolean("isHost") {
			t.Error("quickplay tables have no host")
		}
	}

	if len(rooms) != 1 {
		t.Fatalf("four waiting players were split across %d tables: %v", len(rooms), rooms)
	}

	// A fifth player has nowhere to sit at that table, so a second one opens.
	fifth := s.dial("fifth")
	joinQuickplay(fifth)
	fifthJoined := fifth.awaitType(3*time.Second, protocol.TypeJoined)
	if rooms[fifthJoined.str("room")] > 0 {
		t.Fatal("a fifth player was seated at a table that already had four")
	}
}

func TestFourHumansPlayAQuickplayGameToTheEnd(t *testing.T) {
	s := newStack(t)

	clients := make([]*testClient, 4)
	for i := range clients {
		clients[i] = s.dial("player")
		joinQuickplay(clients[i])
		clients[i].awaitType(3*time.Second, protocol.TypeJoined)
	}

	results := make(chan *engine.View, 4)
	for _, c := range clients {
		go func(c *testClient) { results <- c.drive(40 * time.Second) }(c)
	}

	var first *engine.View
	for i := 0; i < 4; i++ {
		view := <-results
		if view.Phase != engine.PhaseGameOver {
			t.Fatalf("a player ended in phase %q", view.Phase)
		}
		for _, p := range view.Players {
			if p.Kind == engine.KindBot {
				t.Fatal("a four-human quickplay table must contain no bots")
			}
		}
		if first == nil {
			first = view
			continue
		}
		for seat := 0; seat < 4; seat++ {
			if view.Totals[seat] != first.Totals[seat] {
				t.Fatalf("players disagree on seat %d's total: %v vs %v",
					seat, view.Totals[seat], first.Totals[seat])
			}
		}
	}
}

func TestQuickplayFillsTheEmptySeatsWithBotsOnceItCanStart(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 150 * time.Millisecond
	})

	alice, bob := s.dial("Alice"), s.dial("Bob")
	for _, c := range []*testClient{alice, bob} {
		joinQuickplay(c)
		c.awaitType(2*time.Second, protocol.TypeJoined)
	}

	done := make(chan *engine.View, 1)
	go func() { done <- bob.drive(40 * time.Second) }()
	final := alice.drive(40 * time.Second)
	<-done

	if final.Phase != engine.PhaseGameOver {
		t.Fatalf("game ended in phase %q", final.Phase)
	}
	bots := 0
	for _, p := range final.Players {
		if p.Kind == engine.KindBot {
			bots++
		}
	}
	if bots != 2 {
		t.Fatalf("a two-player table had %d bots, want 2", bots)
	}
}

func TestQuickplayRestartNeedsEveryConnectedHuman(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 100 * time.Millisecond
	})

	a, b := s.dial("a"), s.dial("b")
	joinQuickplay(a)
	joinQuickplay(b)
	a.awaitType(3*time.Second, protocol.TypeJoined)
	b.awaitType(3*time.Second, protocol.TypeJoined)

	done := make(chan *engine.View, 1)
	go func() { done <- b.drive(40 * time.Second) }()
	a.drive(40 * time.Second)
	<-done

	// One player asking for a rematch is not enough — the other is still
	// reading the final scoreboard.
	a.send(map[string]any{"type": protocol.TypeRestart})
	ready := a.await(2*time.Second, "a readyState frame", func(f frame) bool {
		return f.Type == protocol.TypeEvent && f.str("event") == protocol.EventReadyState
	})
	if ready.num("ready") != 1 || ready.num("total") != 2 {
		t.Fatalf("readyState = %d/%d, want 1/2", ready.num("ready"), ready.num("total"))
	}
	a.expectNo(300*time.Millisecond, "a fresh deal from a one-sided restart", func(f frame) bool {
		return f.Type == protocol.TypeEvent && f.str("event") == "handStart"
	})

	// Once both agree, the table deals a brand-new game from a clean slate.
	b.send(map[string]any{"type": protocol.TypeRestart})
	var fresh engine.View
	a.await(3*time.Second, "a freshly dealt game", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.HandIndex != 0 || v.Phase != engine.PhaseBidding {
			return false
		}
		fresh = v
		return true
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

// TestQuickplaySeparatesTablesByHandsPerGame proves the matchmaking pools are
// bucketed by hand count: a Quickplay (3 hands) seeker and a Normal Play (5
// hands) seeker both use room:"QUICKPLAY", but must never land at the same
// table, while two seekers who want the same variant do gather together.
func TestQuickplaySeparatesTablesByHandsPerGame(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		cfg.MatchFillWait = 30 * time.Second
	})

	// Two players both asking for a 3-hand game land at the same table.
	a3, b3 := s.dial("A3"), s.dial("B3")
	joinQuickplayWithHands(a3, 3)
	joinQuickplayWithHands(b3, 3)
	a3.awaitType(2*time.Second, protocol.TypeJoined)
	b3.awaitType(2*time.Second, protocol.TypeJoined)
	awaitLobbyWith(t, a3, 2, 3*time.Second)
	awaitLobbyWith(t, b3, 2, 3*time.Second)

	// A player asking for a 5-hand game must not be seated with them, even
	// though every one of them sent the same QUICKPLAY sentinel.
	c5 := s.dial("C5")
	joinQuickplayWithHands(c5, 5)
	c5.awaitType(2*time.Second, protocol.TypeJoined)
	awaitLobbyWith(t, c5, 1, 2*time.Second)

	// And the 3-hand table must not suddenly grow a third seat because of it.
	a3.expectNo(500*time.Millisecond, "a third player joining the 3-hand table", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.num("humansSeated") == 3
	})
}

// TestQuickplayViewReportsRequestedHandsPerGame proves the hand count a
// player asked for when creating a fresh table is what actually gets dealt,
// round-tripped back through the view frame's handsPerGame field.
func TestQuickplayViewReportsRequestedHandsPerGame(t *testing.T) {
	s := newStack(t, func(cfg *config.Config, _ *room.Pacing) {
		// Low enough that a single player is enough to deal, so the test does
		// not need a second connection to observe the dealt view.
		cfg.MatchMinPlayers = 1
		cfg.MatchFillWait = 50 * time.Millisecond
	})

	alice := s.dial("Alice")
	joinQuickplayWithHands(alice, 3)
	alice.awaitType(2*time.Second, protocol.TypeJoined)

	dealt := alice.await(3*time.Second, "a dealt view", func(f frame) bool {
		return f.Type == protocol.TypeView
	})
	var v engine.View
	if err := decodeInto(dealt.Data, &v); err != nil {
		t.Fatalf("decode view: %v", err)
	}
	if v.HandsPerGame != 3 {
		t.Fatalf("handsPerGame = %d, want 3", v.HandsPerGame)
	}
}
