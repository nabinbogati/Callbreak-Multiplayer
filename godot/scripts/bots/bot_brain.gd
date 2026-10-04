class_name BotBrain
extends RefCounted

## Heuristic Call Break opponent.
##
## Two jobs: guess how many tricks a hand is worth at bidding time, and pick a
## card during play. Both run off the same idea — count the tricks you actually
## control (top cards, long trumps, ruffing chances) and then play to hit that
## number, since undershooting your bid costs you the whole thing while an
## overtrick is only worth 0.1.

var difficulty: String
var _rng: RandomNumberGenerator


func _init(difficulty_in := "normal", rng: RandomNumberGenerator = null) -> void:
	difficulty = difficulty_in
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	_rng = rng


func _noise() -> float:
	match difficulty:
		"easy": return 1.4
		"hard": return 0.0
	return 0.5


func _blunder_rate() -> float:
	match difficulty:
		"easy": return 0.25
		"hard": return 0.0
	return 0.06


# ---------------------------------------------------------------- bidding

func choose_bid(hand: Array) -> int:
	var estimate := Rules.estimate_tricks(hand)
	var noise := _noise()
	var jitter := 0.0 if noise == 0.0 else (_rng.randf() * 2.0 - 1.0) * noise
	return Rules.clamp_bid(Rules.round_half_away(estimate + jitter))


# ------------------------------------------------------------------- play

## Picks a card to play. [param played] is every face-up card this hand,
## including the ones already in [param trick].
func choose_card(hand: Array, trick: Array, played: Array, bid: int, tricks_won: int) -> String:
	var legal := Rules.legal_moves(hand, trick)
	if legal.size() == 1:
		return legal[0]
	var blunder := _blunder_rate()
	if blunder > 0.0 and _rng.randf() < blunder:
		return legal[_rng.randi_range(0, legal.size() - 1)]

	var unseen := _unseen_cards(hand, played)
	var need := bid - tricks_won
	var tricks_left := hand.size()

	if trick.is_empty():
		return _choose_lead(legal, hand, unseen, need, tricks_left)
	return _choose_follow(legal, trick, unseen, need)


func _choose_lead(legal: Array[String], hand: Array, unseen: Array, need: int, tricks_left: int) -> String:
	# A side-suit master is a trick nobody can take from you — always worth it,
	# since even a bid you have already made earns 0.1 for the overtrick.
	var side_masters := legal.filter(func(c): return not Cards.is_trump(c) and _is_master(c, unseen))
	if not side_masters.is_empty():
		return _best_master_to_lead(side_masters, hand)

	var trumps := legal.filter(func(c): return Cards.is_trump(c))

	if need > 0:
		# Needing every remaining trick means there is nothing left to protect.
		if need >= tricks_left and not trumps.is_empty():
			return Cards.highest(trumps)

		var trump_masters := trumps.filter(func(c): return _is_master(c, unseen))
		if not trump_masters.is_empty():
			return Cards.lowest(trump_masters)

		# Long trumps: draw the opponents' out so the small ones become good.
		if trumps.size() >= 5:
			return Cards.highest(trumps)

	return _safe_discard(legal, hand)


func _choose_follow(legal: Array[String], trick: Array, unseen: Array, need: int) -> String:
	var winners := legal.filter(func(c): return Rules.would_win(trick, c))
	if winners.is_empty():
		return _safe_discard(legal, legal)

	var cheapest_winner := _cheapest(winners)
	var losers := legal.filter(func(c): return not Rules.would_win(trick, c))
	var is_last := trick.size() == 3

	if need > 0:
		return cheapest_winner

	# Bid already covered: take the trick only when it costs nothing. Playing
	# last is certain, and a master wins without spending a trump.
	if losers.is_empty():
		return cheapest_winner
	if is_last and not Cards.is_trump(cheapest_winner):
		return cheapest_winner
	if not Cards.is_trump(cheapest_winner) and _is_master(cheapest_winner, unseen):
		return cheapest_winner
	return _safe_discard(losers, losers)


# ------------------------------------------------------------------ theory

## Cards that are neither in [param hand] nor already face up — i.e. what the
## other three seats might still be holding.
func _unseen_cards(hand: Array, played: Array) -> Array[String]:
	var out: Array[String] = []
	for c in Cards.full_deck():
		if not hand.has(c) and not played.has(c):
			out.append(c)
	return out


## No opponent can still hold a higher card of this suit.
func _is_master(card: String, unseen: Array) -> bool:
	var s := Cards.suit(card)
	var r := Cards.rank(card)
	for c in unseen:
		if Cards.suit(c) == s and Cards.rank(c) > r:
			return false
	return true


## Among masters, cash the one from the longest suit first — the extra cards
## behind it are the ones that might grow into tricks later.
func _best_master_to_lead(masters: Array, hand: Array) -> String:
	var sorted := masters.duplicate()
	sorted.sort_custom(func(a, b):
		var la := Cards.of_suit(hand, Cards.suit(a)).size()
		var lb := Cards.of_suit(hand, Cards.suit(b)).size()
		if la != lb:
			return la > lb
		return Cards.rank(a) > Cards.rank(b))
	return sorted[0]


## Cheapest way to win: spend a side card before a trump, and a low one before
## a high one.
func _cheapest(cards: Array) -> String:
	var sorted := cards.duplicate()
	sorted.sort_custom(func(a, b): return _cost(a) < _cost(b))
	return sorted[0]


func _cost(card: String) -> int:
	return (100 if Cards.is_trump(card) else 0) + Cards.rank(card)


## Throw the least useful card: never a trump if there is a choice, lowest rank
## first, and from a shorter suit when it is a coin toss — going void there is
## what buys a ruff later.
func _safe_discard(options: Array, hand: Array) -> String:
	var sorted := options.duplicate()
	sorted.sort_custom(func(a, b):
		var ca := _cost(a)
		var cb := _cost(b)
		if ca != cb:
			return ca < cb
		return Cards.of_suit(hand, Cards.suit(a)).size() < Cards.of_suit(hand, Cards.suit(b)).size())
	return sorted[0]
