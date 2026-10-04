class_name Rules
extends RefCounted

## Call Break rules: which cards may be played, who takes the trick, and what a
## hand is worth.

const HANDS_PER_GAME := 5
const TRICKS_PER_HAND := 13
const MIN_BID := 1
const MAX_BID := 13


## Expected trick count for [param hand], in fractional tricks.
##
## Honours are discounted when they lack the length to protect them (a bare
## king falls to the ace), and shortness only pays off as ruffing value while
## there are trumps left to ruff with. Deterministic — no randomness — so it is
## the shared heuristic behind both the bots' bids and the human bid
## suggestion ([method suggest_bid]).
static func estimate_tricks(hand: Array) -> float:
	var trumps := Cards.of_suit(hand, Cards.TRUMP_SUIT)
	var trump_count := trumps.size()
	var has_trump := func(r: int) -> bool:
		for c in trumps:
			if Cards.rank(c) == r:
				return true
		return false

	var tricks := 0.0

	# Top trumps are near-certain; each needs a spare trump behind it to survive.
	if has_trump.call(14): tricks += 1.0
	if has_trump.call(13): tricks += 0.9 if trump_count >= 2 else 0.5
	if has_trump.call(12): tricks += 0.7 if trump_count >= 3 else 0.3
	if has_trump.call(11): tricks += 0.45 if trump_count >= 4 else 0.15

	# Spare length in trumps eventually wins tricks by exhaustion.
	tricks += max(0, trump_count - 4) * 0.5

	var ruff_value := 0.0
	for s in 4:
		if s == Cards.TRUMP_SUIT:
			continue
		var cards := Cards.of_suit(hand, s)
		var n := cards.size()
		var ranks := cards.map(func(c): return Cards.rank(c))

		if ranks.has(14): tricks += 0.9
		if ranks.has(13): tricks += 0.65 if n >= 2 else 0.25
		if ranks.has(12): tricks += 0.4 if n >= 3 else 0.1
		if ranks.has(11): tricks += 0.2 if n >= 4 else 0.0

		if n == 0:
			ruff_value += min(trump_count, 3) * 0.5
		elif n == 1 and trump_count >= 2:
			ruff_value += min(trump_count - 1, 2) * 0.35
		elif n == 2 and trump_count >= 3:
			ruff_value += 0.15

	# You can only ruff as often as you hold spare trumps.
	tricks += min(ruff_value, float(max(0, trump_count - 1)))

	return tricks


## Starting bid [param hand] deserves: the rounded, clamped expected trick count.
static func suggest_bid(hand: Array) -> int:
	return clamp_bid(round_half_away(estimate_tricks(hand)))


## Dart's `double.round()` rounds half away from zero; so does this.
static func round_half_away(value: float) -> int:
	return int(sign(value) * floor(abs(value) + 0.5))


## The cards [param hand] may legally play into [param trick] (plays in table
## order, each `{seat, card}`).
##
## 1. Leading is free.
## 2. Holding the led suit you must follow it, and you must beat the best card
##    of that suit already played if you can — the "heading" rule.
## 3. Void in the led suit you must trump, and if the trick is already trumped
##    you must overtrump when able. Unable to overtrump, you may discard
##    anything, spades included.
static func legal_moves(hand: Array, trick: Array) -> Array[String]:
	var all: Array[String] = []
	all.assign(hand)
	if trick.is_empty():
		return all

	var led := Cards.suit(trick[0]["card"])
	var in_suit := Cards.of_suit(hand, led)

	if not in_suit.is_empty():
		var best_led := 0
		for p in trick:
			if Cards.suit(p["card"]) == led:
				best_led = max(best_led, Cards.rank(p["card"]))
		var higher: Array[String] = []
		for c in in_suit:
			if Cards.rank(c) > best_led:
				higher.append(c)
		return higher if not higher.is_empty() else in_suit

	# Void in the led suit. If the led suit *is* trump, holding no trump leaves
	# every card legal, which the empty check below already covers.
	var trumps := Cards.of_suit(hand, Cards.TRUMP_SUIT)
	if trumps.is_empty():
		return all

	var best_trump := 0
	for p in trick:
		if Cards.is_trump(p["card"]):
			best_trump = max(best_trump, Cards.rank(p["card"]))
	if best_trump == 0:
		return trumps

	var over: Array[String] = []
	for c in trumps:
		if Cards.rank(c) > best_trump:
			over.append(c)
	return over if not over.is_empty() else all


static func is_legal_play(hand: Array, trick: Array, card: String) -> bool:
	return legal_moves(hand, trick).has(card)


## The seat that takes [param trick]: highest trump, else highest card of the
## led suit.
static func trick_winner(trick: Array) -> int:
	var led := Cards.suit(trick[0]["card"])
	var contenders := trick.filter(func(p): return Cards.is_trump(p["card"]))
	if contenders.is_empty():
		contenders = trick.filter(func(p): return Cards.suit(p["card"]) == led)
	var best: Dictionary = contenders[0]
	for p in contenders:
		if Cards.rank(p["card"]) > Cards.rank(best["card"]):
			best = p
	return int(best["seat"])


## Whether [param card] would be winning [param trick] if it were played into it
## right now.
static func would_win(trick: Array, card: String) -> bool:
	if trick.is_empty():
		return true
	var with_card := trick.duplicate()
	with_card.append(Cards.play(-1, card))
	return trick_winner(with_card) == -1


## Make your bid and you score it, plus 0.1 per overtrick. Fall short and you
## lose the bid outright.
static func score_hand(bid: int, tricks_won: int) -> float:
	var raw: float = bid + (tricks_won - bid) * 0.1 if tricks_won >= bid else -float(bid)
	return round_tenth(raw)


static func round_tenth(value: float) -> float:
	return round_half_away(value * 10.0) / 10.0


static func clamp_bid(bid: int) -> int:
	return clampi(bid, MIN_BID, MAX_BID)
