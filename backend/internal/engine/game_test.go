package engine

import (
	"encoding/json"
	"math"
	"math/rand/v2"
	"testing"
)

func testTable() [4]PlayerInfo {
	var players [4]PlayerInfo
	for seat := 0; seat < 4; seat++ {
		players[seat] = PlayerInfo{
			Seat:       seat,
			Name:       "Bot",
			Kind:       KindBot,
			Difficulty: Normal,
			Connected:  true,
		}
	}
	return players
}

func newTestGame(seed uint64) *Game {
	return NewGame(testTable(), HandsPerGame, rand.New(rand.NewPCG(seed, seed^0x9e3779b9)))
}

// playFullGame drives a game to completion with a trivial "first legal card"
// strategy, synchronously and with no timers, returning the trick log. The bot
// brain has its own end-to-end test; this one isolates the state machine.
func playFullGame(t *testing.T, g *Game) []CompletedTrick {
	t.Helper()
	g.Start()

	var tricks []CompletedTrick
	for guard := 0; g.Phase != PhaseGameOver; guard++ {
		if guard > 10_000 {
			t.Fatal("game failed to terminate")
		}
		switch g.Phase {
		case PhaseBidding:
			seat := *g.Turn
			if !g.PlaceBid(seat, SuggestBid(g.HandOf(seat))) {
				t.Fatalf("bid rejected for seat %d", seat)
			}
		case PhasePlaying:
			seat := *g.Turn
			legal := g.LegalMovesFor(seat)
			if len(legal) == 0 {
				t.Fatalf("seat %d is on the clock with no legal move", seat)
			}
			if !g.PlayCard(seat, legal[0]) {
				t.Fatalf("legal card %v rejected for seat %d", legal[0], seat)
			}
			if g.AwaitingTrickClr {
				tricks = append(tricks, *g.LastTrick)
				g.ClearTrick()
			}
		case PhaseHandOver:
			g.NextHand()
		default:
			t.Fatalf("unexpected phase %q", g.Phase)
		}
	}
	return tricks
}

func TestFullGameInvariants(t *testing.T) {
	for seed := uint64(0); seed < 40; seed++ {
		g := newTestGame(seed)
		tricks := playFullGame(t, g)

		if len(tricks) != HandsPerGame*TricksPerHand {
			t.Fatalf("seed %d: played %d tricks, want %d", seed, len(tricks), HandsPerGame*TricksPerHand)
		}

		for _, trick := range tricks {
			if len(trick.Plays) != 4 {
				t.Fatalf("seed %d: trick has %d plays", seed, len(trick.Plays))
			}
			seats := map[int]bool{}
			for _, p := range trick.Plays {
				seats[p.Seat] = true
			}
			if len(seats) != 4 {
				t.Fatalf("seed %d: a seat played twice in one trick", seed)
			}
			if got := TrickWinner(trick.Plays); got != trick.Winner {
				t.Fatalf("seed %d: recorded winner %d, recomputed %d", seed, trick.Winner, got)
			}
		}

		// Across a hand every one of the 52 cards appears exactly once, and the
		// 13 tricks are distributed among the four seats.
		for hand := 0; hand < HandsPerGame; hand++ {
			handTricks := tricks[hand*TricksPerHand : (hand+1)*TricksPerHand]
			seen := map[Card]bool{}
			total := 0
			var wonBySeat [4]int
			for _, trick := range handTricks {
				for _, p := range trick.Plays {
					if seen[p.Card] {
						t.Fatalf("seed %d hand %d: card %v played twice", seed, hand, p.Card)
					}
					seen[p.Card] = true
					total++
				}
				wonBySeat[trick.Winner]++
			}
			if total != 52 || len(seen) != 52 {
				t.Fatalf("seed %d hand %d: saw %d cards (%d distinct)", seed, hand, total, len(seen))
			}
			if wonBySeat[0]+wonBySeat[1]+wonBySeat[2]+wonBySeat[3] != TricksPerHand {
				t.Fatalf("seed %d hand %d: tricks do not sum to 13", seed, hand)
			}
		}

		for seat := 0; seat < 4; seat++ {
			if len(g.RoundScores[seat]) != HandsPerGame {
				t.Fatalf("seed %d: seat %d has %d round scores", seed, seat, len(g.RoundScores[seat]))
			}
			sum := 0.0
			for _, s := range g.RoundScores[seat] {
				sum += s
			}
			if math.Abs(g.Totals[seat]-Round1(sum)) > 1e-9 {
				t.Fatalf("seed %d: seat %d total %v != sum of rounds %v", seed, seat, g.Totals[seat], sum)
			}
		}

		ranked := map[int]bool{}
		for _, r := range g.Rankings {
			ranked[r.Seat] = true
		}
		if len(ranked) != 4 {
			t.Fatalf("seed %d: rankings cover %d seats", seed, len(ranked))
		}
		// Rankings must be ordered best first.
		for i := 1; i < len(g.Rankings); i++ {
			if g.Rankings[i-1].Total < g.Rankings[i].Total {
				t.Fatalf("seed %d: rankings not sorted descending: %+v", seed, g.Rankings)
			}
			if g.Rankings[i].Place != i+1 {
				t.Fatalf("seed %d: place %d out of order", seed, g.Rankings[i].Place)
			}
		}
	}
}

func TestBiddingOrderStartsLeftOfDealer(t *testing.T) {
	g := newTestGame(1)
	g.Start()
	// Dealer starts at 3 and advances before the first deal, so seat 0 deals and
	// seat 1 bids first — the same convention as the client engine.
	if g.Dealer != 0 {
		t.Fatalf("first dealer = %d, want 0", g.Dealer)
	}
	if *g.Turn != 1 {
		t.Fatalf("first to bid = %d, want 1", *g.Turn)
	}
	for i := 0; i < 4; i++ {
		seat := *g.Turn
		want := (1 + i) % 4
		if seat != want {
			t.Fatalf("bid %d went to seat %d, want %d", i, seat, want)
		}
		g.PlaceBid(seat, 3)
	}
	if g.Phase != PhasePlaying {
		t.Fatalf("phase after four bids = %q, want playing", g.Phase)
	}
	if *g.Turn != 1 {
		t.Fatalf("first to lead = %d, want 1", *g.Turn)
	}
}

func TestRejectsOutOfTurnAndIllegalMoves(t *testing.T) {
	g := newTestGame(2)
	g.Start()

	if g.PlaceBid(2, 3) {
		t.Error("accepted a bid from a seat that is not on the clock")
	}
	if g.PlayCard(1, g.HandOf(1)[0]) {
		t.Error("accepted a card during the bidding phase")
	}

	for i := 0; i < 4; i++ {
		g.PlaceBid(*g.Turn, 3)
	}
	if g.PlaceBid(1, 5) {
		t.Error("accepted a second bid from a seat that already bid")
	}

	leader := *g.Turn
	notInHand := findCardNotIn(g.HandOf(leader))
	if g.PlayCard(leader, notInHand) {
		t.Error("accepted a card the seat does not hold")
	}

	// After the lead, a seat holding the led suit must not be able to discard.
	lead := g.LegalMovesFor(leader)[0]
	if !g.PlayCard(leader, lead) {
		t.Fatal("legal lead rejected")
	}
	next := *g.Turn
	legal := idSet(g.LegalMovesFor(next))
	for _, c := range g.HandOf(next) {
		if legal[c.ID()] {
			continue
		}
		if g.PlayCard(next, c) {
			t.Fatalf("accepted illegal card %v for seat %d", c, next)
		}
	}
}

func findCardNotIn(hand []Card) Card {
	held := map[Card]bool{}
	for _, c := range hand {
		held[c] = true
	}
	for _, c := range FullDeck() {
		if !held[c] {
			return c
		}
	}
	panic("a 13-card hand cannot hold the whole deck")
}

func TestViewRedaction(t *testing.T) {
	g := newTestGame(1)
	g.Start()

	view := g.ViewFor(0)
	if len(view.Hand) != 13 {
		t.Fatalf("own hand has %d cards, want 13", len(view.Hand))
	}
	if view.HandCounts != [4]int{13, 13, 13, 13} {
		t.Fatalf("hand counts = %v", view.HandCounts)
	}
	if view.You == nil || *view.You != 0 {
		t.Fatal("view does not identify its own seat")
	}

	// The decisive property: nothing in seat 0's view reveals another seat's
	// cards. Only counts cross the boundary.
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	mine := idSet(g.HandOf(0))
	for seat := 1; seat < 4; seat++ {
		for _, c := range g.HandOf(seat) {
			if mine[c.ID()] {
				continue
			}
			if containsToken(string(encoded), `"`+c.ID()+`"`) {
				t.Fatalf("seat 0's view leaks %v from seat %d", c, seat)
			}
		}
	}

	spectator := g.ViewFor(-1)
	if len(spectator.Hand) != 0 || len(spectator.LegalMoveIDs) != 0 {
		t.Fatal("a spectator view must carry no cards")
	}
	if spectator.You != nil {
		t.Fatal("a spectator view must not claim a seat")
	}
}

func containsToken(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

func TestViewJSONRoundTrip(t *testing.T) {
	g := newTestGame(3)
	g.Start()
	for i := 0; i < 4; i++ {
		g.PlaceBid(*g.Turn, 2+i)
	}
	seat := *g.Turn
	g.PlayCard(seat, g.LegalMovesFor(seat)[0])

	original := g.ViewFor(seat)
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}

	var decoded View
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("a view the server produced must decode again: %v", err)
	}
	again, err := json.Marshal(&decoded)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != string(again) {
		t.Fatalf("round trip changed the encoding:\n first: %s\nsecond: %s", data, again)
	}
}

// TestViewJSONShape pins the exact keys the Godot client's GameView.from_dict
// reads. Renaming or dropping one of these breaks every connected client.
func TestViewJSONShape(t *testing.T) {
	g := newTestGame(4)
	g.Start()
	data, err := json.Marshal(g.ViewFor(0))
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	required := []string{
		"phase", "handIndex", "handsPerGame", "dealer", "turn", "players", "you",
		"hand", "legalMoveIds", "handCounts", "bids", "tricksWon", "trick",
		"trickNumber", "awaitingTrickClear", "lastTrick", "roundScores", "totals",
		"rankings",
	}
	for _, key := range required {
		if _, ok := raw[key]; !ok {
			t.Errorf("view JSON is missing %q, which the Godot client requires", key)
		}
	}
	// Nullable fields must serialise as null, not be omitted: fromJson reads
	// them unconditionally.
	if string(raw["lastTrick"]) != "null" {
		t.Errorf("lastTrick = %s, want null before any trick completes", raw["lastTrick"])
	}
	if string(raw["bids"]) != "[null,null,null,null]" {
		t.Errorf("bids = %s, want four nulls before bidding", raw["bids"])
	}
	if string(raw["phase"]) != `"bidding"` {
		t.Errorf("phase = %s, want the client's phase name (GameView.PLAYING etc.)", raw["phase"])
	}
}

func TestEventsDrain(t *testing.T) {
	g := newTestGame(5)
	g.Start()
	events := g.TakeEvents()
	if len(events) != 1 {
		t.Fatalf("Start produced %d events, want 1", len(events))
	}
	if got := events[0].Wire()["event"]; got != "handStart" {
		t.Fatalf("first event = %v, want handStart", got)
	}
	if len(g.TakeEvents()) != 0 {
		t.Fatal("TakeEvents must drain")
	}
}

// The final hand must end the game outright. The between-hands scoreboard
// ("Next round" popup) is for mid-game hands only, so the last round has to go
// straight to gameOver — otherwise online players see a stray scoreboard after
// the winner is already decided.
func TestLastHandEndsTheGameNotTheScoreboard(t *testing.T) {
	for seed := uint64(0); seed < 40; seed++ {
		g := newTestGame(seed)
		g.Start()

		scoreboards := 0
		for guard := 0; g.Phase != PhaseGameOver; guard++ {
			if guard > 10_000 {
				t.Fatalf("seed %d: game failed to terminate", seed)
			}
			switch g.Phase {
			case PhaseBidding:
				g.PlaceBid(*g.Turn, SuggestBid(g.HandOf(*g.Turn)))
			case PhasePlaying:
				seat := *g.Turn
				if !g.PlayCard(seat, g.LegalMovesFor(seat)[0]) {
					t.Fatalf("seed %d: legal card rejected", seed)
				}
				if g.AwaitingTrickClr {
					g.ClearTrick()
				}
			case PhaseHandOver:
				// The scoreboard belongs to mid-game hands only: being asked for
				// "next round" on the final round is exactly the bug this pins.
				if g.HandIndex+1 >= g.TotalHands {
					t.Fatalf("seed %d: last round entered the scoreboard", seed)
				}
				scoreboards++
				g.NextHand()
			default:
				t.Fatalf("seed %d: unexpected phase %q", seed, g.Phase)
			}
		}
		if scoreboards != HandsPerGame-1 {
			t.Fatalf("seed %d: %d scoreboards shown, want %d (one per non-final hand)",
				seed, scoreboards, HandsPerGame-1)
		}
	}
}

func TestSetPlayerDoesNotDisturbTheHand(t *testing.T) {
	g := newTestGame(6)
	g.Start()
	before := g.HandOf(2)

	g.SetPlayer(2, PlayerInfo{Name: "Bot", Kind: KindBot, Difficulty: Hard, Connected: false})

	if got := g.Player(2); got.Seat != 2 || got.Kind != KindBot || got.Connected {
		t.Fatalf("SetPlayer produced %+v", got)
	}
	after := g.HandOf(2)
	if len(before) != len(after) {
		t.Fatal("swapping a seat's occupant must not touch their cards")
	}
	for i := range before {
		if before[i] != after[i] {
			t.Fatal("swapping a seat's occupant must not touch their cards")
		}
	}
}
