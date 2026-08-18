package engine

import "math"

// Game shape constants. Mirrors frontend/lib/engine/rules.dart.
const (
	HandsPerGame  = 5
	TricksPerHand = 13
	MinBid        = 1
	MaxBid        = 13
)

// EstimateTricks is the expected trick count for a hand, in fractional tricks.
//
// Honours are discounted when they lack the length to protect them (a bare king
// falls to the ace), and shortness only pays off as ruffing value while there
// are trumps left to ruff with. Deterministic — it is the shared heuristic
// behind both the bots' bids and the human bid suggestion.
func EstimateTricks(hand []Card) float64 {
	var bySuit [4][]Card
	for _, s := range AllSuits {
		bySuit[s] = OfSuit(hand, s)
	}
	trumps := bySuit[TrumpSuit]
	trumpCount := len(trumps)
	hasTrump := func(rank int) bool {
		for _, c := range trumps {
			if c.Rank == rank {
				return true
			}
		}
		return false
	}

	tricks := 0.0

	// Top trumps are near-certain; each needs a spare trump behind it to survive.
	if hasTrump(14) {
		tricks += 1.0
	}
	if hasTrump(13) {
		if trumpCount >= 2 {
			tricks += 0.9
		} else {
			tricks += 0.5
		}
	}
	if hasTrump(12) {
		if trumpCount >= 3 {
			tricks += 0.7
		} else {
			tricks += 0.3
		}
	}
	if hasTrump(11) {
		if trumpCount >= 4 {
			tricks += 0.45
		} else {
			tricks += 0.15
		}
	}

	// Spare length in trumps eventually wins tricks by exhaustion.
	if trumpCount > 4 {
		tricks += float64(trumpCount-4) * 0.5
	}

	ruffValue := 0.0
	for _, suit := range AllSuits {
		if suit == TrumpSuit {
			continue
		}
		cards := bySuit[suit]
		n := len(cards)
		has := func(rank int) bool {
			for _, c := range cards {
				if c.Rank == rank {
					return true
				}
			}
			return false
		}

		if has(14) {
			tricks += 0.9
		}
		if has(13) {
			if n >= 2 {
				tricks += 0.65
			} else {
				tricks += 0.25
			}
		}
		if has(12) {
			if n >= 3 {
				tricks += 0.4
			} else {
				tricks += 0.1
			}
		}
		if has(11) && n >= 4 {
			tricks += 0.2
		}

		switch {
		case n == 0:
			ruffValue += float64(min(trumpCount, 3)) * 0.5
		case n == 1 && trumpCount >= 2:
			ruffValue += float64(min(trumpCount-1, 2)) * 0.35
		case n == 2 && trumpCount >= 3:
			ruffValue += 0.15
		}
	}

	// You can only ruff as often as you hold spare trumps.
	tricks += math.Min(ruffValue, float64(max(0, trumpCount-1)))

	return tricks
}

// SuggestBid is the starting bid a hand deserves: rounded, clamped estimate.
func SuggestBid(hand []Card) int { return ClampBid(roundHalfAway(EstimateTricks(hand))) }

// LegalMoves returns the cards hand may legally play into trick (table order).
//
//  1. Leading is free.
//  2. Holding the led suit you must follow it, and you must beat the best card
//     of that suit already played if you can — the "heading" rule.
//  3. Void in the led suit you must trump, and if the trick is already trumped
//     you must overtrump when able. Unable to overtrump, you may discard
//     anything, spades included.
func LegalMoves(hand []Card, trick []TrickPlay) []Card {
	if len(trick) == 0 {
		out := make([]Card, len(hand))
		copy(out, hand)
		return out
	}

	led := trick[0].Card.Suit
	inSuit := OfSuit(hand, led)

	if len(inSuit) > 0 {
		bestLed := 0
		for _, p := range trick {
			if p.Card.Suit == led && p.Card.Rank > bestLed {
				bestLed = p.Card.Rank
			}
		}
		higher := make([]Card, 0, len(inSuit))
		for _, c := range inSuit {
			if c.Rank > bestLed {
				higher = append(higher, c)
			}
		}
		if len(higher) > 0 {
			return higher
		}
		return inSuit
	}

	// Void in the led suit. If the led suit *is* trump, holding no trump leaves
	// every card legal, which the empty check below already covers.
	trumps := OfSuit(hand, TrumpSuit)
	if len(trumps) == 0 {
		out := make([]Card, len(hand))
		copy(out, hand)
		return out
	}

	bestTrump := 0
	trumped := false
	for _, p := range trick {
		if p.Card.IsTrump() {
			trumped = true
			if p.Card.Rank > bestTrump {
				bestTrump = p.Card.Rank
			}
		}
	}
	if !trumped {
		return trumps
	}

	higher := make([]Card, 0, len(trumps))
	for _, c := range trumps {
		if c.Rank > bestTrump {
			higher = append(higher, c)
		}
	}
	if len(higher) > 0 {
		return higher
	}
	out := make([]Card, len(hand))
	copy(out, hand)
	return out
}

// IsLegalPlay reports whether card is among the legal moves.
func IsLegalPlay(hand []Card, trick []TrickPlay, card Card) bool {
	return Contains(LegalMoves(hand, trick), card)
}

// TrickWinner is the seat that takes the trick: highest trump, else highest
// card of the led suit. Panics on an empty trick — never called with one.
func TrickWinner(trick []TrickPlay) int {
	led := trick[0].Card.Suit
	var contenders []TrickPlay
	for _, p := range trick {
		if p.Card.IsTrump() {
			contenders = append(contenders, p)
		}
	}
	if len(contenders) == 0 {
		for _, p := range trick {
			if p.Card.Suit == led {
				contenders = append(contenders, p)
			}
		}
	}
	best := contenders[0]
	for _, p := range contenders[1:] {
		if p.Card.Rank > best.Card.Rank {
			best = p
		}
	}
	return best.Seat
}

// WouldWin reports whether card would be taking the trick if played right now.
func WouldWin(trick []TrickPlay, card Card) bool {
	if len(trick) == 0 {
		return true
	}
	probe := make([]TrickPlay, len(trick), len(trick)+1)
	copy(probe, trick)
	probe = append(probe, TrickPlay{Seat: -1, Card: card})
	return TrickWinner(probe) == -1
}

// ScoreHand: make your bid and you score it, plus 0.1 per overtrick. Fall short
// and you lose the bid outright.
//
// The rounding must match Dart's `(raw * 10).round() / 10`, whose .round() ties
// away from zero — which is exactly math.Round's behaviour.
func ScoreHand(bid, tricksWon int) float64 {
	var raw float64
	if tricksWon >= bid {
		raw = float64(bid) + float64(tricksWon-bid)*0.1
	} else {
		raw = -float64(bid)
	}
	return Round1(raw)
}

// Round1 snaps a score to one decimal place the same way the Dart client does.
// Applied after every addition so totals never drift into float dust.
func Round1(v float64) float64 { return math.Round(v*10) / 10 }

// ClampBid holds a bid inside the legal range.
func ClampBid(bid int) int {
	if bid < MinBid {
		return MinBid
	}
	if bid > MaxBid {
		return MaxBid
	}
	return bid
}

// roundHalfAway matches Dart's num.round(), which rounds halves away from zero
// (Go's default int conversion truncates, and math.Round is the right primitive).
func roundHalfAway(v float64) int { return int(math.Round(v)) }
