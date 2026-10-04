class_name Cards
extends RefCounted

## Card primitives for Call Break. Spades are the permanent trump suit.
##
## A card is represented everywhere as its wire id — `"AS"`, `"10H"` — so it
## compares by value, serialises for free, and crosses the socket unchanged.
## These helpers read rank and suit back out of an id.

enum Suit { SPADES, HEARTS, DIAMONDS, CLUBS }

const TRUMP_SUIT := Suit.SPADES

const SUIT_CODES := ["S", "H", "D", "C"]
const SUIT_SYMBOLS := ["♠", "♥", "♦", "♣"]
const SUIT_LABELS := ["Spades", "Hearts", "Diamonds", "Clubs"]

## Rank values run 2..14, so the ace is high.
const MIN_RANK := 2
const MAX_RANK := 14


static func rank_label(value: int) -> String:
	match value:
		14: return "A"
		13: return "K"
		12: return "Q"
		11: return "J"
	return str(value)


static func rank_from_label(label: String) -> int:
	match label.to_upper():
		"A": return 14
		"K": return 13
		"Q": return 12
		"J": return 11
	return int(label)


static func make(rank_value: int, suit_value: int) -> String:
	return rank_label(rank_value) + SUIT_CODES[suit_value]


static func suit_from_code(code: String) -> int:
	return SUIT_CODES.find(code.to_upper())


static func rank(card: String) -> int:
	return rank_from_label(card.substr(0, card.length() - 1))


static func suit(card: String) -> int:
	return suit_from_code(card.substr(card.length() - 1))


static func label(card: String) -> String:
	return card.substr(0, card.length() - 1)


static func is_trump(card: String) -> bool:
	return suit(card) == TRUMP_SUIT


static func is_red(card: String) -> bool:
	var s := suit(card)
	return s == Suit.HEARTS or s == Suit.DIAMONDS


static func is_valid(card: String) -> bool:
	if card.length() < 2 or card.length() > 3:
		return false
	var s := suit(card)
	var r := rank(card)
	return s >= 0 and r >= MIN_RANK and r <= MAX_RANK and make(r, s) == card.to_upper()


## A full 52-card deck in a canonical order.
static func full_deck() -> Array[String]:
	var deck: Array[String] = []
	for s in 4:
		for r in range(MIN_RANK, MAX_RANK + 1):
			deck.append(make(r, s))
	return deck


## Deals 13 cards to each of the four seats.
static func deal_hands(rng: RandomNumberGenerator) -> Array:
	var deck := full_deck()
	shuffle(deck, rng)
	var hands := []
	for seat in 4:
		hands.append(sort_for_display(deck.slice(seat * 13, seat * 13 + 13)))
	return hands


## Fisher–Yates with an explicit generator, so a seeded game is reproducible.
static func shuffle(list: Array, rng: RandomNumberGenerator) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = list[i]
		list[i] = list[j]
		list[j] = tmp


## Display order: trumps first, then the other suits, each ranked high to low.
static func sort_for_display(hand: Array) -> Array[String]:
	var sorted: Array[String] = []
	sorted.assign(hand)
	sorted.sort_custom(func(a: String, b: String) -> bool:
		var sa := suit(a)
		var sb := suit(b)
		if sa != sb:
			return sa < sb
		return rank(a) > rank(b))
	return sorted


static func of_suit(cards: Array, suit_value: int) -> Array[String]:
	var out: Array[String] = []
	for c in cards:
		if suit(c) == suit_value:
			out.append(c)
	return out


static func lowest(cards: Array) -> String:
	var best: String = cards[0]
	for c in cards:
		if rank(c) < rank(best):
			best = c
	return best


static func highest(cards: Array) -> String:
	var best: String = cards[0]
	for c in cards:
		if rank(c) > rank(best):
			best = c
	return best


## One card laid on the table by one seat, in wire shape.
static func play(seat: int, card: String) -> Dictionary:
	return {"seat": seat, "card": card}
