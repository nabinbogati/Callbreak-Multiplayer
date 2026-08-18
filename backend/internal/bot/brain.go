// Package bot is the heuristic Call Break opponent, ported from
// frontend/lib/bots/bot.dart.
//
// It has two jobs: guess how many tricks a hand is worth at bidding time, and
// pick a card during play. Both run off the same idea — count the tricks you
// actually control (top cards, long trumps, ruffing chances) and then play to
// hit that number, since undershooting your bid costs you the whole thing while
// an overtrick is only worth 0.1.
//
// The server also uses a brain to cover disconnected and timed-out seats, so a
// dropped player's table still finishes at a reasonable standard of play.
package bot

import (
	"math"
	"math/rand/v2"
	"sort"

	"github.com/nabin31bogati/callbreak/backend/internal/engine"
)

// Brain is not safe for concurrent use; each room owns its own.
type Brain struct {
	Difficulty engine.Difficulty
	rng        *rand.Rand
}

func New(difficulty engine.Difficulty, rng *rand.Rand) *Brain {
	return &Brain{Difficulty: difficulty, rng: rng}
}

// noise is how far a bid may wander from the honest estimate.
func (b *Brain) noise() float64 {
	switch b.Difficulty {
	case engine.Easy:
		return 1.4
	case engine.Hard:
		return 0.0
	default:
		return 0.5
	}
}

// blunderRate is how often the bot throws a random legal card instead of
// thinking. It is what makes easy bots beatable.
func (b *Brain) blunderRate() float64 {
	switch b.Difficulty {
	case engine.Easy:
		return 0.25
	case engine.Hard:
		return 0.0
	default:
		return 0.06
	}
}

// ---------------------------------------------------------------- bidding

func (b *Brain) ChooseBid(hand []engine.Card) int {
	estimate := engine.EstimateTricks(hand)
	n := b.noise()
	jitter := 0.0
	if n != 0 {
		jitter = (b.rng.Float64()*2 - 1) * n
	}
	// math.Round ties away from zero, matching Dart's num.round().
	return engine.ClampBid(int(math.Round(estimate + jitter)))
}

// ------------------------------------------------------------------- play

// Move is everything the brain needs to pick a card.
type Move struct {
	Hand      []engine.Card
	Trick     []engine.TrickPlay
	Played    []engine.Card // every face-up card this hand, including the trick
	Bid       int
	TricksWon int
}

// ChooseCard picks a card to play. It always returns a legal one; if the seat
// somehow has no legal move the zero card comes back with ok=false, which the
// caller treats as a bug rather than a game state.
func (b *Brain) ChooseCard(m Move) (engine.Card, bool) {
	legal := engine.LegalMoves(m.Hand, m.Trick)
	if len(legal) == 0 {
		return engine.Card{}, false
	}
	if len(legal) == 1 {
		return legal[0], true
	}
	if rate := b.blunderRate(); rate > 0 && b.rng.Float64() < rate {
		return legal[b.rng.IntN(len(legal))], true
	}

	unseen := unseenCards(m.Hand, m.Played)
	need := m.Bid - m.TricksWon
	tricksLeft := len(m.Hand)

	if len(m.Trick) == 0 {
		return b.chooseLead(legal, m.Hand, unseen, need, tricksLeft), true
	}
	return b.chooseFollow(legal, m.Trick, unseen, need), true
}

func (b *Brain) chooseLead(legal, hand, unseen []engine.Card, need, tricksLeft int) engine.Card {
	// A side-suit master is a trick nobody can take from you — always worth it,
	// since even a bid you have already made earns 0.1 for the overtrick.
	var sideMasters []engine.Card
	for _, c := range legal {
		if !c.IsTrump() && isMaster(c, unseen) {
			sideMasters = append(sideMasters, c)
		}
	}
	if len(sideMasters) > 0 {
		return bestMasterToLead(sideMasters, hand)
	}

	var trumps []engine.Card
	for _, c := range legal {
		if c.IsTrump() {
			trumps = append(trumps, c)
		}
	}

	if need > 0 {
		// Needing every remaining trick means there is nothing left to protect.
		if need >= tricksLeft && len(trumps) > 0 {
			return engine.Highest(trumps)
		}

		var trumpMasters []engine.Card
		for _, c := range trumps {
			if isMaster(c, unseen) {
				trumpMasters = append(trumpMasters, c)
			}
		}
		if len(trumpMasters) > 0 {
			return engine.Lowest(trumpMasters)
		}

		// Long trumps: draw the opponents' out so the small ones become good.
		if len(trumps) >= 5 {
			return engine.Highest(trumps)
		}
	}

	return safeDiscard(legal, hand)
}

func (b *Brain) chooseFollow(legal []engine.Card, trick []engine.TrickPlay, unseen []engine.Card, need int) engine.Card {
	var winners, losers []engine.Card
	for _, c := range legal {
		if engine.WouldWin(trick, c) {
			winners = append(winners, c)
		} else {
			losers = append(losers, c)
		}
	}
	if len(winners) == 0 {
		return safeDiscard(legal, legal)
	}

	cheapestWinner := cheapest(winners)
	isLast := len(trick) == 3

	if need > 0 {
		return cheapestWinner
	}

	// Bid already covered: take the trick only when it costs nothing. Playing
	// last is certain, and a master wins without spending a trump.
	if len(losers) == 0 {
		return cheapestWinner
	}
	if isLast && !cheapestWinner.IsTrump() {
		return cheapestWinner
	}
	if !cheapestWinner.IsTrump() && isMaster(cheapestWinner, unseen) {
		return cheapestWinner
	}
	return safeDiscard(losers, losers)
}

// ------------------------------------------------------------------ theory

// unseenCards is what the other three seats might still be holding: everything
// neither in this hand nor already face up.
func unseenCards(hand, played []engine.Card) []engine.Card {
	known := make(map[engine.Card]struct{}, len(hand)+len(played))
	for _, c := range hand {
		known[c] = struct{}{}
	}
	for _, c := range played {
		known[c] = struct{}{}
	}
	out := make([]engine.Card, 0, 52-len(known))
	for _, c := range engine.FullDeck() {
		if _, seen := known[c]; !seen {
			out = append(out, c)
		}
	}
	return out
}

// isMaster reports that no opponent can still hold a higher card of this suit.
func isMaster(card engine.Card, unseen []engine.Card) bool {
	for _, c := range unseen {
		if c.Suit == card.Suit && c.Rank > card.Rank {
			return false
		}
	}
	return true
}

// bestMasterToLead cashes the master from the longest suit first — the extra
// cards behind it are the ones that might grow into tricks later.
func bestMasterToLead(masters, hand []engine.Card) engine.Card {
	sorted := append([]engine.Card(nil), masters...)
	sort.SliceStable(sorted, func(i, j int) bool {
		li := len(engine.OfSuit(hand, sorted[i].Suit))
		lj := len(engine.OfSuit(hand, sorted[j].Suit))
		if li != lj {
			return li > lj
		}
		return sorted[i].Rank > sorted[j].Rank
	})
	return sorted[0]
}

// cheapest is the least costly way to win: a side card before a trump, and a
// low one before a high one.
func cheapest(cards []engine.Card) engine.Card {
	sorted := append([]engine.Card(nil), cards...)
	sort.SliceStable(sorted, func(i, j int) bool { return cost(sorted[i]) < cost(sorted[j]) })
	return sorted[0]
}

func cost(c engine.Card) int {
	if c.IsTrump() {
		return 100 + c.Rank
	}
	return c.Rank
}

// safeDiscard throws the least useful card: never a trump if there is a choice,
// lowest rank first, and from a shorter suit when it is a coin toss — going void
// there is what buys a ruff later.
func safeDiscard(options, hand []engine.Card) engine.Card {
	sorted := append([]engine.Card(nil), options...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if ci, cj := cost(sorted[i]), cost(sorted[j]); ci != cj {
			return ci < cj
		}
		return len(engine.OfSuit(hand, sorted[i].Suit)) < len(engine.OfSuit(hand, sorted[j].Suit))
	})
	return sorted[0]
}
