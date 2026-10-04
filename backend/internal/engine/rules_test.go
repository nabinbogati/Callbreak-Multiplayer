package engine

import (
	"math"
	"testing"
)

// These cases are ported one-for-one from godot/tests/test_engine.gd. If a
// case here diverges from the client suite, the client and server disagree about
// the rules, which is the one bug class this port cannot afford.

func cards(ids ...string) []Card {
	out := make([]Card, len(ids))
	for i, id := range ids {
		out[i] = MustParseCard(id)
	}
	return out
}

func idSet(cs []Card) map[string]bool {
	out := make(map[string]bool, len(cs))
	for _, c := range cs {
		out[c.ID()] = true
	}
	return out
}

func assertSameCards(t *testing.T, got, want []Card) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %v (%d cards), want %v (%d cards)", got, len(got), want, len(want))
	}
	g, w := idSet(got), idSet(want)
	for id := range w {
		if !g[id] {
			t.Fatalf("got %v, want %v (missing %s)", got, want, id)
		}
	}
}

func TestParseCardRoundTrip(t *testing.T) {
	for _, c := range FullDeck() {
		got, err := ParseCard(c.ID())
		if err != nil {
			t.Fatalf("ParseCard(%q): %v", c.ID(), err)
		}
		if got != c {
			t.Fatalf("ParseCard(%q) = %v, want %v", c.ID(), got, c)
		}
	}
}

func TestParseCardRejectsGarbage(t *testing.T) {
	// Card ids come straight off an untrusted socket, so every one of these has
	// to be an error rather than a panic or a silently wrong card.
	for _, id := range []string{"", "S", "1S", "15S", "AX", "AA", "0S", "-1S", "10", "  AS", "10SS"} {
		if _, err := ParseCard(id); err == nil {
			t.Errorf("ParseCard(%q) accepted an invalid id", id)
		}
	}
}

func TestScoreHand(t *testing.T) {
	tests := []struct {
		bid, won int
		want     float64
	}{
		{5, 5, 5.0},  // making the bid exactly scores the bid
		{3, 6, 3.3},  // overtricks add 0.1 each
		{7, 3, -7.0}, // falling short loses the bid outright
		{7, 0, -7.0}, // ...regardless of how few were won
		{1, 13, 2.2}, // a wild overshoot is still only worth 0.1 a trick
		{13, 13, 13.0},
	}
	for _, tc := range tests {
		if got := ScoreHand(tc.bid, tc.won); math.Abs(got-tc.want) > 1e-9 {
			t.Errorf("ScoreHand(%d, %d) = %v, want %v", tc.bid, tc.won, got, tc.want)
		}
	}
}

func TestClampBid(t *testing.T) {
	for _, tc := range []struct{ in, want int }{{0, 1}, {-5, 1}, {14, 13}, {99, 13}, {7, 7}} {
		if got := ClampBid(tc.in); got != tc.want {
			t.Errorf("ClampBid(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestEstimateTricksSmallHandIsWorthNothing(t *testing.T) {
	var hand []Card
	for r := 2; r <= 6; r++ {
		hand = append(hand, Card{r, Hearts})
	}
	for r := 2; r <= 7; r++ {
		hand = append(hand, Card{r, Clubs})
	}
	hand = append(hand, Card{2, Diamonds}, Card{3, Diamonds})

	if len(hand) != 13 {
		t.Fatalf("test hand has %d cards", len(hand))
	}
	if got := EstimateTricks(hand); got != 0 {
		t.Errorf("EstimateTricks = %v, want 0", got)
	}
	if got := SuggestBid(hand); got != MinBid {
		t.Errorf("SuggestBid = %d, want %d", got, MinBid)
	}
}

func TestEstimateTricksMonsterHand(t *testing.T) {
	hand := cards("AS", "KS", "QS", "JS", "10S", "9S", "AH", "KH", "QH", "AC", "KC", "QC", "AD")
	got := SuggestBid(hand)
	if got < 8 || got > MaxBid {
		t.Errorf("SuggestBid = %d, want between 8 and %d", got, MaxBid)
	}
}

func TestEstimateTricksLoneKingIsHalfATrick(t *testing.T) {
	hand := []Card{{13, Hearts}}
	for r := 2; r <= 8; r++ {
		hand = append(hand, Card{r, Clubs})
	}
	for r := 2; r <= 6; r++ {
		hand = append(hand, Card{r, Diamonds})
	}
	if len(hand) != 13 {
		t.Fatalf("test hand has %d cards", len(hand))
	}
	if got := EstimateTricks(hand); got >= 1.0 {
		t.Errorf("EstimateTricks = %v, want < 1.0 for an unprotected lone king", got)
	}
}

func TestLegalMovesLeadingIsUnrestricted(t *testing.T) {
	hand := cards("AH", "2C", "10S")
	assertSameCards(t, LegalMoves(hand, nil), hand)
}

func TestLegalMovesMustFollowAndHead(t *testing.T) {
	hand := cards("5H", "JH", "2C")
	trick := []TrickPlay{{Seat: 3, Card: MustParseCard("9H")}}
	assertSameCards(t, LegalMoves(hand, trick), cards("JH"))
}

func TestLegalMovesUnableToHeadMayFollowLow(t *testing.T) {
	hand := cards("3H", "5H", "2C")
	trick := []TrickPlay{{Seat: 3, Card: MustParseCard("9H")}}
	assertSameCards(t, LegalMoves(hand, trick), cards("3H", "5H"))
}

func TestLegalMovesVoidMustTrump(t *testing.T) {
	hand := cards("3S", "9S", "2C")
	trick := []TrickPlay{{Seat: 3, Card: MustParseCard("9H")}}
	assertSameCards(t, LegalMoves(hand, trick), cards("3S", "9S"))
}

func TestLegalMovesMustOvertrump(t *testing.T) {
	hand := cards("3S", "9S", "2C")
	trick := []TrickPlay{
		{Seat: 2, Card: MustParseCard("9H")},
		{Seat: 3, Card: MustParseCard("5S")},
	}
	assertSameCards(t, LegalMoves(hand, trick), cards("9S"))
}

func TestLegalMovesUnableToOvertrumpAnythingGoes(t *testing.T) {
	hand := cards("3S", "2C")
	trick := []TrickPlay{
		{Seat: 2, Card: MustParseCard("9H")},
		{Seat: 3, Card: MustParseCard("QS")},
	}
	assertSameCards(t, LegalMoves(hand, trick), hand)
}

func TestLegalMovesLedTrumpWithNoTrumps(t *testing.T) {
	// Spades led and the hand is void in them: every card is legal, and the
	// "must trump" branch must not fire on an empty trump holding.
	hand := cards("3H", "2C", "9D")
	trick := []TrickPlay{{Seat: 0, Card: MustParseCard("KS")}}
	assertSameCards(t, LegalMoves(hand, trick), hand)
}

func TestLegalMovesDoesNotAliasTheHand(t *testing.T) {
	// LegalMoves returns slices the caller may sort or truncate; it must never
	// hand back the engine's own hand storage.
	hand := cards("AH", "2C", "10S")
	got := LegalMoves(hand, nil)
	got[0] = MustParseCard("2D")
	if hand[0].ID() != "AH" {
		t.Fatalf("LegalMoves aliased the input hand: %v", hand)
	}
}

func TestTrickWinner(t *testing.T) {
	tests := []struct {
		name  string
		trick []TrickPlay
		want  int
	}{
		{
			name: "highest of the led suit",
			trick: []TrickPlay{
				{0, MustParseCard("5H")}, {1, MustParseCard("KH")},
				{2, MustParseCard("2H")}, {3, MustParseCard("9H")},
			},
			want: 1,
		},
		{
			name: "any trump beats every side card",
			trick: []TrickPlay{
				{0, MustParseCard("AH")}, {1, MustParseCard("2S")},
				{2, MustParseCard("KH")}, {3, MustParseCard("QH")},
			},
			want: 1,
		},
		{
			name: "highest trump wins an overtrumped trick",
			trick: []TrickPlay{
				{0, MustParseCard("AH")}, {1, MustParseCard("2S")},
				{2, MustParseCard("5S")}, {3, MustParseCard("3S")},
			},
			want: 2,
		},
		{
			name: "off-suit discards never win",
			trick: []TrickPlay{
				{0, MustParseCard("3H")}, {1, MustParseCard("AC")},
				{2, MustParseCard("AD")}, {3, MustParseCard("2H")},
			},
			want: 0,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := TrickWinner(tc.trick); got != tc.want {
				t.Errorf("TrickWinner = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestWouldWin(t *testing.T) {
	if !WouldWin(nil, MustParseCard("2C")) {
		t.Error("leading always wins an empty trick")
	}
	trick := []TrickPlay{{0, MustParseCard("9H")}, {1, MustParseCard("2S")}}
	if WouldWin(trick, MustParseCard("AH")) {
		t.Error("an ace of a side suit cannot beat a trump")
	}
	if !WouldWin(trick, MustParseCard("3S")) {
		t.Error("a higher trump should take the trick")
	}
}

func TestSortForDisplayIsTrumpsFirstThenHighToLow(t *testing.T) {
	got := SortForDisplay(cards("2C", "AD", "5H", "KS", "2S", "AH"))
	want := []string{"KS", "2S", "AH", "5H", "AD", "2C"}
	for i, c := range got {
		if c.ID() != want[i] {
			t.Fatalf("SortForDisplay = %v, want %v", got, want)
		}
	}
}
