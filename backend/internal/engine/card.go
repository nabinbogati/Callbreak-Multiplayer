// Package engine is the authoritative Call Break state machine.
//
// It is a faithful port of the Dart engine in frontend/lib/engine/ — card.dart,
// rules.dart and game.dart. The client runs the same logic locally for its
// offline mode, so any divergence here shows up as a desynced table. Every
// exported symbol below has a named counterpart in the Dart source; when you
// change one, change both.
//
// The package is pure: no timers, no I/O, no goroutines. A room actor drives it.
package engine

import (
	"fmt"
	"math/rand/v2"
	"sort"
	"strconv"
	"strings"
)

// Suit values are ordered exactly as the Dart enum, because the display sort
// and the JSON wire format both depend on the ordinal.
type Suit int

const (
	Spades Suit = iota
	Hearts
	Diamonds
	Clubs
)

// TrumpSuit is permanent in Call Break — spades always beat everything else.
const TrumpSuit = Spades

// Code is the single-letter wire form used inside a card id.
func (s Suit) Code() string {
	switch s {
	case Spades:
		return "S"
	case Hearts:
		return "H"
	case Diamonds:
		return "D"
	case Clubs:
		return "C"
	}
	return "?"
}

func (s Suit) String() string {
	switch s {
	case Spades:
		return "spades"
	case Hearts:
		return "hearts"
	case Diamonds:
		return "diamonds"
	case Clubs:
		return "clubs"
	}
	return "unknown"
}

func (s Suit) IsTrump() bool { return s == TrumpSuit }

// AllSuits is iteration order for suit-wise scans, matching Dart's Suit.values.
var AllSuits = [4]Suit{Spades, Hearts, Diamonds, Clubs}

// SuitFromCode parses the letter form. Returns an error rather than panicking,
// since card ids arrive from untrusted clients.
func SuitFromCode(code string) (Suit, error) {
	switch strings.ToUpper(code) {
	case "S":
		return Spades, nil
	case "H":
		return Hearts, nil
	case "D":
		return Diamonds, nil
	case "C":
		return Clubs, nil
	}
	return 0, fmt.Errorf("engine: unknown suit code %q", code)
}

// Ranks run 2..14 so the ace is high and comparisons are plain integer ones.
const (
	MinRank = 2
	MaxRank = 14
)

// RankLabel is the face form used in a card id: A, K, Q, J or the number.
func RankLabel(v int) string {
	switch v {
	case 14:
		return "A"
	case 13:
		return "K"
	case 12:
		return "Q"
	case 11:
		return "J"
	}
	return strconv.Itoa(v)
}

// RankFromLabel is the inverse of RankLabel, validated for untrusted input.
func RankFromLabel(label string) (int, error) {
	switch strings.ToUpper(label) {
	case "A":
		return 14, nil
	case "K":
		return 13, nil
	case "Q":
		return 12, nil
	case "J":
		return 11, nil
	}
	v, err := strconv.Atoi(label)
	if err != nil || v < MinRank || v > 10 {
		return 0, fmt.Errorf("engine: invalid rank %q", label)
	}
	return v, nil
}

// Card is a comparable value type, so cards can be map keys and compared with
// ==. Keep it that way: the engine leans on equality all over.
type Card struct {
	Rank int
	Suit Suit
}

func (c Card) IsTrump() bool { return c.Suit == TrumpSuit }

// ID is the stable wire id, e.g. "AS", "10H". Matches PlayingCard.id in Dart.
func (c Card) ID() string { return RankLabel(c.Rank) + c.Suit.Code() }

func (c Card) String() string { return c.ID() }

// ParseCard reads a wire id. The suit is the final byte; everything before it
// is the rank label.
func ParseCard(id string) (Card, error) {
	if len(id) < 2 {
		return Card{}, fmt.Errorf("engine: malformed card id %q", id)
	}
	suit, err := SuitFromCode(id[len(id)-1:])
	if err != nil {
		return Card{}, err
	}
	rank, err := RankFromLabel(id[:len(id)-1])
	if err != nil {
		return Card{}, err
	}
	return Card{Rank: rank, Suit: suit}, nil
}

// MustParseCard is for tests and static tables only.
func MustParseCard(id string) Card {
	c, err := ParseCard(id)
	if err != nil {
		panic(err)
	}
	return c
}

// FullDeck returns all 52 cards in canonical order.
func FullDeck() []Card {
	deck := make([]Card, 0, 52)
	for _, s := range AllSuits {
		for r := MinRank; r <= MaxRank; r++ {
			deck = append(deck, Card{Rank: r, Suit: s})
		}
	}
	return deck
}

// ShuffleKind selects the algorithm used to randomize the deck before a deal.
//
// Zero value is FisherYates, the uniform shuffle — so a zero-valued DealConfig
// is always the fair default.
type ShuffleKind int

const (
	// ShuffleFisherYates is the standard uniform shuffle. Every one of the 52!
	// orders is equally likely, which is the strongest fairness guarantee the
	// game can offer.
	ShuffleFisherYates ShuffleKind = iota
	// ShuffleRiffle simulates a physical riffle (cut the deck, interleave the
	// two halves) repeated a few times. Seven passes is comfortably past the
	// mixing threshold for a 52-card deck, so it stays fair while keeping the
	// "someone shuffled a real deck" feel.
	ShuffleRiffle
	// ShuffleOverhand simulates an overhand shuffle, the other classic human
	// shuffle. Deliberately imperfect — it is the flavour variant.
	ShuffleOverhand
	// ShuffleBalanced keeps the deal random but rejects hands that are too
	// lopsided, so no single seat draws a runaway strong hand. It is the only
	// non-uniform option, and it exists for casual play where even, competitive
	// hands matter more than cryptographic purity.
	ShuffleBalanced
)

// DealStyle selects how the shuffled deck is handed out to the four seats.
type DealStyle int

const (
	// DealSequential cuts the deck into four 13-card blocks. Fast, and fair
	// because the deck was shuffled first.
	DealSequential DealStyle = iota
	// DealRoundRobin deals one card at a time around the table — the classic
	// deal, seat 0 through seat 3 repeated thirteen times.
	DealRoundRobin
	// DealBatched deals the way Call Break is usually dealt by hand: four
	// round-robin rounds of three cards, then a final round of one card to each
	// seat (3‑3‑3‑3‑1).
	DealBatched
)

// DealConfig picks both the shuffle and the distribution for a deal. The zero
// value is the fair default (uniform shuffle, sequential cut).
type DealConfig struct {
	Shuffle ShuffleKind
	Style   DealStyle
}

// DefaultDealConfig is the provably fair shuffle-and-cut the game always used.
func DefaultDealConfig() DealConfig {
	return DealConfig{Shuffle: ShuffleFisherYates, Style: DealSequential}
}

// DealConfigFromPreset resolves a wire preset name ("fair", "physical",
// "balanced") into a full shuffle + distribution config. Anything unrecognized
// falls back to the fair default, exactly like a client that never sent one.
func DealConfigFromPreset(preset string) DealConfig {
	switch preset {
	case "physical":
		return DealConfig{Shuffle: ShuffleRiffle, Style: DealBatched}
	case "balanced":
		return DealConfig{Shuffle: ShuffleBalanced, Style: DealRoundRobin}
	default:
		return DefaultDealConfig()
	}
}

// DealHands shuffles a deck and deals a fair random hand to each of the four
// seats using the default config. Convenience wrapper kept for the callers and
// tests that have no opinion on how the deck is handled.
func DealHands(rng *rand.Rand) [4][]Card {
	return DealHandsWith(DefaultDealConfig(), rng)
}

// DealHandsWith shuffles a deck according to cfg.Shuffle and deals it out
// according to cfg.Style, returning each seat's sorted hand. The shuffle and
// the distribution are independent: any shuffle can be paired with any deal
// style.
//
// Unlike the Dart version there is no reproducible seed contract: the server is
// the only dealer, so the shuffle only has to be fair. rng is seeded from
// crypto/rand per room by the caller.
func DealHandsWith(cfg DealConfig, rng *rand.Rand) [4][]Card {
	var hands [4][]Card
	if cfg.Shuffle == ShuffleBalanced {
		// Balanced measures the dealt hands themselves, so it runs its own
		// shuffle-and-deal loop against the requested distribution.
		hands = balancedDeal(cfg.Style, rng)
	} else {
		deck := FullDeck()
		shuffleDeck(deck, cfg.Shuffle, rng)
		hands = distributeDeck(deck, cfg.Style)
	}
	for seat := 0; seat < 4; seat++ {
		hands[seat] = SortForDisplay(hands[seat])
	}
	return hands
}

// shuffleDeck permutes deck in place according to kind.
func shuffleDeck(deck []Card, kind ShuffleKind, rng *rand.Rand) {
	switch kind {
	case ShuffleRiffle:
		for i := 0; i < 7; i++ {
			riffle(deck, rng)
		}
	case ShuffleOverhand:
		for i := 0; i < 8; i++ {
			overhand(deck, rng)
		}
	default:
		rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
	}
}

// riffle simulates one pass of a physical riffle shuffle: cut the deck into two
// hands near the middle, then interleave runs of cards from each hand. Run
// lengths are random (1–3), so a single pass is noticeably biased, exactly like
// the real thing.
func riffle(deck []Card, rng *rand.Rand) {
	n := len(deck)
	cut := n/2 + rng.IntN(9) - 4
	if cut < 8 {
		cut = 8
	}
	if cut > n-8 {
		cut = n - 8
	}
	left, right := deck[:cut], deck[cut:]
	out := make([]Card, 0, n)
	li, ri := 0, 0
	for li < len(left) || ri < len(right) {
		fromLeft := false
		switch {
		case li >= len(left):
			fromLeft = false
		case ri >= len(right):
			fromLeft = true
		default:
			// Weighted toward whichever hand still holds more cards.
			fromLeft = rng.IntN(len(left)-li+len(right)-ri) < len(left)-li
		}
		run := 1 + rng.IntN(3)
		for k := 0; k < run; k++ {
			if fromLeft {
				if li >= len(left) {
					break
				}
				out = append(out, left[li])
				li++
			} else {
				if ri >= len(right) {
					break
				}
				out = append(out, right[ri])
				ri++
			}
		}
	}
	copy(deck, out)
}

// overhand simulates one overhand shuffle: packets of cards are lifted off the
// top and dropped back onto the other hand, one packet at a time. Imperfect on
// purpose — it is the "human shuffled" variant.
func overhand(deck []Card, rng *rand.Rand) {
	out := make([]Card, 0, len(deck))
	remaining := deck
	for len(remaining) > 0 {
		packet := 1 + rng.IntN(20)
		if packet > len(remaining) {
			packet = len(remaining)
		}
		packetCards := append([]Card(nil), remaining[:packet]...)
		// The packet lands on top of everything already stacked.
		out = append(packetCards, out...)
		remaining = remaining[packet:]
	}
	copy(deck, out)
}

// distributeDeck hands the shuffled deck out to the four seats according to
// style. Each returned hand is a fresh slice.
func distributeDeck(deck []Card, style DealStyle) [4][]Card {
	var hands [4][]Card
	switch style {
	case DealRoundRobin:
		for i, c := range deck {
			hands[i%4] = append(hands[i%4], c)
		}
	case DealBatched:
		// Four round-robin rounds of three cards, then a final single card to
		// each seat — the way Call Break is dealt by hand (3‑3‑3‑3‑1).
		pos := 0
		for round := 0; round < 4; round++ {
			for seat := 0; seat < 4; seat++ {
				for k := 0; k < 3; k++ {
					hands[seat] = append(hands[seat], deck[pos])
					pos++
				}
			}
		}
		for seat := 0; seat < 4; seat++ {
			hands[seat] = append(hands[seat], deck[pos])
			pos++
		}
	default: // DealSequential
		for seat := 0; seat < 4; seat++ {
			hands[seat] = append([]Card(nil), deck[seat*13:seat*13+13]...)
		}
	}
	return hands
}

// balanceThreshold is the largest acceptable spread (strongest minus weakest
// hand strength) for a balanced deal. Tuned so most deals pass untouched and
// the rest only shave off the most lopsided ones.
const balanceThreshold = 14

// balancedDeal samples random deals (uniform shuffle + the requested deal
// style) and returns the first whose hands are close enough in strength, or the
// best of a capped number of attempts. Rejection sampling keeps every returned
// deal uniformly random subject to the balance constraint — the strength filter
// is the only bias.
func balancedDeal(style DealStyle, rng *rand.Rand) [4][]Card {
	const attempts = 60
	bestSpread := 1 << 30
	var best [4][]Card
	for i := 0; i < attempts; i++ {
		deck := FullDeck()
		rng.Shuffle(len(deck), func(a, b int) { deck[a], deck[b] = deck[b], deck[a] })
		hands := distributeDeck(deck, style)
		if spread := handSpread(hands); spread <= balanceThreshold {
			return hands
		} else if spread < bestSpread {
			bestSpread = spread
			best = hands
		}
	}
	return best
}

// handStrength values one hand: every card contributes its rank, and trumps
// count for roughly double because they decide tricks. Higher is stronger.
func handStrength(hand []Card) int {
	s := 0
	for _, c := range hand {
		v := c.Rank - MinRank // 0..12
		if c.IsTrump() {
			v = v*2 + 6
		}
		s += v
	}
	return s
}

// handSpread is how far the strongest hand sits above the weakest.
func handSpread(hands [4][]Card) int {
	best := handStrength(hands[0])
	worst := best
	for _, h := range hands[1:] {
		if s := handStrength(h); s > best {
			best = s
		} else if s < worst {
			worst = s
		}
	}
	return best - worst
}

// SortForDisplay orders a hand trumps-first, then by suit ordinal, each suit
// ranked high to low. Returns a new slice; the input is untouched.
func SortForDisplay(hand []Card) []Card {
	out := make([]Card, len(hand))
	copy(out, hand)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Suit != out[j].Suit {
			return out[i].Suit < out[j].Suit
		}
		return out[i].Rank > out[j].Rank
	})
	return out
}

// OfSuit filters a hand to one suit, preserving order.
func OfSuit(cards []Card, suit Suit) []Card {
	out := make([]Card, 0, len(cards))
	for _, c := range cards {
		if c.Suit == suit {
			out = append(out, c)
		}
	}
	return out
}

// Lowest returns the lowest-ranked card. Panics on an empty slice, like Dart's
// reduce — callers always check first.
func Lowest(cards []Card) Card {
	best := cards[0]
	for _, c := range cards[1:] {
		if c.Rank < best.Rank {
			best = c
		}
	}
	return best
}

// Highest returns the highest-ranked card.
func Highest(cards []Card) Card {
	best := cards[0]
	for _, c := range cards[1:] {
		if c.Rank > best.Rank {
			best = c
		}
	}
	return best
}

// Contains reports whether cards holds card.
func Contains(cards []Card, card Card) bool {
	for _, c := range cards {
		if c == card {
			return true
		}
	}
	return false
}

// remove deletes the first occurrence of card, returning the shortened slice.
func remove(cards []Card, card Card) ([]Card, bool) {
	for i, c := range cards {
		if c == card {
			return append(cards[:i:i], cards[i+1:]...), true
		}
	}
	return cards, false
}

// TrickPlay is one card laid on the table by one seat.
type TrickPlay struct {
	Seat int  `json:"seat"`
	Card Card `json:"card"`
}
