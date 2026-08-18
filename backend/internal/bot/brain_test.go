package bot

import (
	"math/rand/v2"
	"testing"

	"github.com/nabin31bogati/callbreak/backend/internal/engine"
)

func newRNG(seed uint64) *rand.Rand {
	return rand.New(rand.NewPCG(seed, seed^0x9e3779b9))
}

func cards(ids ...string) []engine.Card {
	out := make([]engine.Card, len(ids))
	for i, id := range ids {
		out[i] = engine.MustParseCard(id)
	}
	return out
}

func TestHardBotBidsTheSuggestion(t *testing.T) {
	rng := newRNG(7)
	brain := New(engine.Hard, rng)
	for i := 0; i < 20; i++ {
		hand := engine.DealHands(rng)[0]
		if got, want := brain.ChooseBid(hand), engine.SuggestBid(hand); got != want {
			t.Fatalf("hard bot bid %d, want the noiseless suggestion %d", got, want)
		}
	}
}

func TestBidsAlwaysInRange(t *testing.T) {
	rng := newRNG(11)
	for _, d := range []engine.Difficulty{engine.Easy, engine.Normal, engine.Hard} {
		brain := New(d, rng)
		for i := 0; i < 200; i++ {
			hand := engine.DealHands(rng)[i%4]
			bid := brain.ChooseBid(hand)
			if bid < engine.MinBid || bid > engine.MaxBid {
				t.Fatalf("%s bot bid %d, outside [%d,%d]", d, bid, engine.MinBid, engine.MaxBid)
			}
		}
	}
}

// The server plays for disconnected and timed-out seats using a brain, so a
// brain that ever returns an illegal card would corrupt a live table.
func TestChosenCardIsAlwaysLegal(t *testing.T) {
	for _, d := range []engine.Difficulty{engine.Easy, engine.Normal, engine.Hard} {
		for seed := uint64(0); seed < 30; seed++ {
			rng := newRNG(seed)
			g := engine.NewGame(botTable(), engine.HandsPerGame, rng)
			brains := [4]*Brain{}
			for i := range brains {
				brains[i] = New(d, rng)
			}
			g.Start()

			for guard := 0; g.Phase != engine.PhaseGameOver; guard++ {
				if guard > 10_000 {
					t.Fatal("game failed to terminate")
				}
				switch g.Phase {
				case engine.PhaseBidding:
					seat := *g.Turn
					if !g.PlaceBid(seat, brains[seat].ChooseBid(g.HandOf(seat))) {
						t.Fatalf("bid from seat %d rejected", seat)
					}
				case engine.PhasePlaying:
					seat := *g.Turn
					bid := 1
					if g.Bids[seat] != nil {
						bid = *g.Bids[seat]
					}
					card, ok := brains[seat].ChooseCard(Move{
						Hand:      g.HandOf(seat),
						Trick:     g.Trick,
						Played:    g.PlayedThisHand,
						Bid:       bid,
						TricksWon: g.TricksWon[seat],
					})
					if !ok {
						t.Fatalf("brain found no move for seat %d with %d cards", seat, len(g.HandOf(seat)))
					}
					if !g.PlayCard(seat, card) {
						t.Fatalf("%s bot at seat %d chose illegal card %v", d, seat, card)
					}
					if g.AwaitingTrickClr {
						g.ClearTrick()
					}
				case engine.PhaseHandOver:
					g.NextHand()
				default:
					t.Fatalf("unexpected phase %q", g.Phase)
				}
			}
		}
	}
}

func botTable() [4]engine.PlayerInfo {
	var players [4]engine.PlayerInfo
	for seat := range players {
		players[seat] = engine.PlayerInfo{
			Seat: seat, Name: "Bot", Kind: engine.KindBot,
			Difficulty: engine.Normal, Connected: true,
		}
	}
	return players
}

func TestForcedMoveIsTakenWithoutThinking(t *testing.T) {
	brain := New(engine.Easy, newRNG(1)) // easy blunders 25% of the time...
	hand := cards("2C")
	for i := 0; i < 50; i++ {
		card, ok := brain.ChooseCard(Move{Hand: hand, Bid: 3})
		if !ok || card.ID() != "2C" {
			t.Fatalf("a single legal card must always be played, got %v", card)
		}
	}
}

func TestCashesASideSuitMasterWhenLeading(t *testing.T) {
	brain := New(engine.Hard, newRNG(2))
	// Every heart above the king is already gone, so KH is a master: nobody can
	// take it, and it costs no trump.
	played := cards("AH", "2H", "3H", "4H")
	hand := cards("KH", "QH", "2C", "3S")
	card, ok := brain.ChooseCard(Move{Hand: hand, Played: played, Bid: 3, TricksWon: 0})
	if !ok || card.ID() != "KH" {
		t.Fatalf("led %v, want the master KH", card)
	}
}

func TestWinsCheaplyWhenItStillNeedsTricks(t *testing.T) {
	brain := New(engine.Hard, newRNG(3))
	trick := []engine.TrickPlay{{Seat: 0, Card: engine.MustParseCard("9H")}}
	hand := cards("10H", "AH", "2C")
	card, ok := brain.ChooseCard(Move{Hand: hand, Trick: trick, Bid: 3, TricksWon: 0})
	if !ok || card.ID() != "10H" {
		t.Fatalf("played %v, want the cheapest winner 10H", card)
	}
}

func TestKeepsItsTrumpWhenTheTrickIsAlreadyLost(t *testing.T) {
	brain := New(engine.Hard, newRNG(4))
	// Void in hearts and holding only a trump too low to overtrump the queen,
	// so every card is legal and none of them wins. The right discard is the
	// cheap diamond: the trump is still worth a trick later.
	trick := []engine.TrickPlay{
		{Seat: 0, Card: engine.MustParseCard("9H")},
		{Seat: 1, Card: engine.MustParseCard("QS")},
	}
	hand := cards("2S", "3D", "KC")
	card, ok := brain.ChooseCard(Move{Hand: hand, Trick: trick, Bid: 2, TricksWon: 2})
	if !ok {
		t.Fatal("no move chosen")
	}
	if card.ID() != "3D" {
		t.Fatalf("discarded %v, want the cheapest non-trump 3D", card)
	}
}

// Call Break's heading rules mean a legal move set never mixes cards that win
// the trick with cards that lose it: if you can beat what is on the table you
// are obliged to. This pins that property, because the follow-play heuristics
// are written as if the two could coexist (they can in other trick games) and a
// future rules change would silently activate that dormant branch.
func TestWinnersAndLosersNeverCoexistInALegalMoveSet(t *testing.T) {
	rng := newRNG(21)
	for seed := 0; seed < 200; seed++ {
		hands := engine.DealHands(rng)
		var trick []engine.TrickPlay
		for seat := 0; seat < 3; seat++ {
			legal := engine.LegalMoves(hands[seat], trick)
			trick = append(trick, engine.TrickPlay{Seat: seat, Card: legal[rng.IntN(len(legal))]})

			legalNext := engine.LegalMoves(hands[seat+1], trick)
			var wins, loses bool
			for _, c := range legalNext {
				if engine.WouldWin(trick, c) {
					wins = true
				} else {
					loses = true
				}
			}
			if wins && loses {
				t.Fatalf("legal set %v against trick %v contains both winners and losers",
					legalNext, trick)
			}
		}
	}
}
