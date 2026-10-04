class_name CallBreakGame
extends RefCounted

## Authoritative Call Break game state machine.
##
## Pure logic — no timers, no nodes. A host drives it, paces bot moves, and
## hands each seat a redacted [GameView]. That split is what lets the same
## engine back the solo-vs-bots game and a networked table.
##
## Discrete happenings are queued as event dictionaries (`{"event": "play",
## "seat": 2, "card": "AS"}`), named exactly as the server names them on the
## wire, and drained with [method take_events].

var seed_value: int
var total_hands: int
var _rng := RandomNumberGenerator.new()
var _players: Array = []
var _pending_events: Array = []

var phase: String = GameView.LOBBY
var hand_index := 0
## Starts at 3 so the first hand is dealt by seat 0 and led by seat 1.
var dealer := 3
var turn := -1

var _hands: Array = [[], [], [], []]
var bids: Array[int] = [-1, -1, -1, -1]
var tricks_won: Array[int] = [0, 0, 0, 0]
var trick: Array = []
var trick_number := 0
var awaiting_trick_clear := false
var last_trick: Dictionary = {}
var round_scores: Array = [[], [], [], []]
var totals: Array[float] = [0.0, 0.0, 0.0, 0.0]
var rankings: Array = []

## Every card face-up so far this hand — what an honest card-counter knows.
var played_this_hand: Array[String] = []


func _init(players: Array, seed_in := -1, hands := Rules.HANDS_PER_GAME) -> void:
	_players = players.map(func(p): return (p as Dictionary).duplicate())
	total_hands = hands
	seed_value = seed_in if seed_in >= 0 else randi()
	_rng.seed = seed_value


func players() -> Array:
	return _players.map(func(p): return (p as Dictionary).duplicate())


func hand_of(seat: int) -> Array[String]:
	var out: Array[String] = []
	out.assign(_hands[seat])
	return out


func set_player(seat: int, info: Dictionary) -> void:
	_players[seat] = info.duplicate()


## Drains the events accumulated since the last call.
func take_events() -> Array:
	var events := _pending_events
	_pending_events = []
	return events


# ------------------------------------------------------------- lifecycle

func start() -> void:
	if phase != GameView.LOBBY:
		return
	_start_hand(0)


func _start_hand(index: int) -> void:
	hand_index = index
	dealer = (dealer + 1) % 4
	_hands = Cards.deal_hands(_rng)
	bids = [-1, -1, -1, -1]
	tricks_won = [0, 0, 0, 0]
	trick = []
	trick_number = 0
	awaiting_trick_clear = false
	last_trick = {}
	played_this_hand.clear()
	phase = GameView.BIDDING
	turn = (dealer + 1) % 4
	_pending_events.append({"event": "handStart", "handIndex": index})


## Leaves the between-hands summary for the next deal, or ends the game.
func next_hand() -> void:
	if phase != GameView.HAND_OVER:
		return
	if hand_index + 1 >= total_hands:
		_finish()
	else:
		_start_hand(hand_index + 1)


func _finish() -> void:
	phase = GameView.GAME_OVER
	turn = -1
	var seats := [0, 1, 2, 3]
	# Highest total first; ties keep seat order so rankings are deterministic.
	seats.sort_custom(func(a, b):
		if totals[a] != totals[b]:
			return totals[a] > totals[b]
		return a < b)
	rankings = []
	for i in seats.size():
		rankings.append({"seat": seats[i], "place": i + 1, "total": totals[seats[i]]})
	_pending_events.append({"event": "gameOver", "rankings": rankings.duplicate(true)})


# ---------------------------------------------------------------- bidding

func place_bid(seat: int, bid: int) -> bool:
	if phase != GameView.BIDDING or turn != seat or bids[seat] >= 0:
		return false
	var value := Rules.clamp_bid(bid)
	bids[seat] = value
	_pending_events.append({"event": "bid", "seat": seat, "bid": value})

	if not bids.has(-1):
		phase = GameView.PLAYING
		turn = (dealer + 1) % 4
		_pending_events.append({"event": "biddingComplete"})
	else:
		turn = (seat + 1) % 4
	return true


# ------------------------------------------------------------------- play

func legal_moves_for(seat: int) -> Array[String]:
	if phase != GameView.PLAYING or turn != seat or awaiting_trick_clear:
		return []
	return Rules.legal_moves(_hands[seat], trick)


func play_card(seat: int, card: String) -> bool:
	if phase != GameView.PLAYING or turn != seat or awaiting_trick_clear:
		return false
	if not _hands[seat].has(card):
		return false
	if not Rules.is_legal_play(_hands[seat], trick, card):
		return false

	_hands[seat].erase(card)
	played_this_hand.append(card)
	trick.append(Cards.play(seat, card))
	_pending_events.append({"event": "play", "seat": seat, "card": card})

	if trick.size() == 4:
		var winner := Rules.trick_winner(trick)
		awaiting_trick_clear = true
		turn = -1
		last_trick = {"plays": trick.duplicate(true), "winner": winner}
		_pending_events.append({"event": "trickWon", "seat": winner})
	else:
		turn = (seat + 1) % 4
	return true


## Called by the host once the finished trick has been on screen long enough.
func clear_trick() -> void:
	if not awaiting_trick_clear:
		return
	var winner: int = last_trick["winner"]
	tricks_won[winner] += 1
	trick = []
	trick_number += 1
	awaiting_trick_clear = false

	if trick_number >= Rules.TRICKS_PER_HAND:
		_end_hand()
	else:
		turn = winner


func _end_hand() -> void:
	var deltas: Array[float] = []
	for seat in 4:
		deltas.append(Rules.score_hand(bids[seat], tricks_won[seat]))
	for seat in 4:
		round_scores[seat].append(deltas[seat])
		totals[seat] = Rules.round_tenth(totals[seat] + deltas[seat])
	_pending_events.append({"event": "handOver", "handIndex": hand_index, "deltas": deltas.duplicate()})
	if hand_index + 1 >= total_hands:
		_finish()
	else:
		phase = GameView.HAND_OVER
		turn = -1


# ------------------------------------------------------------------ views

## State as [param seat] may see it: own cards in full, everyone else's reduced
## to a count. Pass -1 for a spectator view. [param host] names the player who
## runs this table (-1 on a hostless one) so the seats can show it.
func view_for(seat: int, host := -1) -> GameView:
	var v := GameView.new()
	v.phase = phase
	v.hand_index = hand_index
	v.hands_per_game = total_hands
	v.dealer = dealer
	v.turn = turn
	v.players = players()
	v.you = seat
	if seat >= 0:
		v.hand = Cards.sort_for_display(_hands[seat])
		v.legal_move_ids = legal_moves_for(seat)
	v.hand_counts.assign(_hands.map(func(h): return h.size()))
	v.bids = bids.duplicate()
	v.tricks_won = tricks_won.duplicate()
	v.trick = trick.duplicate(true)
	v.trick_number = trick_number
	v.awaiting_trick_clear = awaiting_trick_clear
	v.last_trick = last_trick.duplicate(true)
	v.round_scores = round_scores.duplicate(true)
	v.totals = totals.duplicate()
	v.rankings = rankings.duplicate(true)
	v.host_seat = host
	return v
