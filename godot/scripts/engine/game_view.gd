class_name GameView
extends RefCounted

## What one seat is allowed to see. Serialisable so it can cross a socket; the
## dictionary shape of [method to_dict] is exactly the `view` frame the game
## server sends (see backend/internal/engine/json.go).
##
## Phases, player kinds and difficulties are kept as their wire strings rather
## than enums, so a view decoded from the network and one built locally are the
## same thing.

const LOBBY := "lobby"
const BIDDING := "bidding"
const PLAYING := "playing"
const HAND_OVER := "handOver"
const GAME_OVER := "gameOver"

var phase: String = LOBBY
var hand_index: int = 0
var hands_per_game: int = Rules.HANDS_PER_GAME
var dealer: int = 0
## Seat to act, or -1 when nobody is on the clock.
var turn: int = -1
## Each `{seat, name, kind, difficulty, connected, autoplay}`.
var players: Array = []
## The seat this view belongs to, or -1 for a spectator.
var you: int = -1
var hand: Array[String] = []
var legal_move_ids: Array[String] = []
var hand_counts: Array[int] = [0, 0, 0, 0]
## A bid per seat, or -1 for "not yet bid".
var bids: Array[int] = [-1, -1, -1, -1]
var tricks_won: Array[int] = [0, 0, 0, 0]
## Plays in table order, each `{seat, card}`.
var trick: Array = []
var trick_number: int = 0
var awaiting_trick_clear: bool = false
## `{plays, winner}` or an empty dictionary.
var last_trick: Dictionary = {}
## `round_scores[seat][hand]`.
var round_scores: Array = [[], [], [], []]
var totals: Array[float] = [0.0, 0.0, 0.0, 0.0]
## Each `{seat, place, total}`.
var rankings: Array = []

## Wall-clock instant (unix millis, server clock) at which the seat on the
## clock is played for automatically. Zero when nothing is timing it.
var turn_deadline_ms: int = 0
## Unix millis (server clock) at which the between-hands scoreboard deals the
## next hand on its own. Zero outside [constant HAND_OVER].
var hand_advance_ms: int = 0
## The server's clock when this view was sent.
var server_time_ms: int = 0
## The seat that may start or restart this table, or -1 on a hostless one.
var host_seat: int = -1


func is_my_turn() -> bool:
	return you >= 0 and turn == you


func i_have_bid() -> bool:
	return you >= 0 and bids[you] >= 0


func hand_number() -> int:
	return hand_index + 1


func can_play(card: String) -> bool:
	return phase == PLAYING and is_my_turn() and legal_move_ids.has(card)


## The trick to draw: the finished one while it lingers, else the live one.
func visible_trick() -> Array:
	if awaiting_trick_clear and not last_trick.is_empty():
		return last_trick["plays"]
	return trick


func player(seat: int) -> Dictionary:
	return players[seat] if seat >= 0 and seat < players.size() else {}


func my_player() -> Dictionary:
	return player(you)


static func is_bot(p: Dictionary) -> bool:
	return p.get("kind", "human") == "bot"


static func initial(name: String) -> String:
	var t := name.strip_edges()
	return "?" if t.is_empty() else t.substr(0, 1).to_upper()


static func make_player(seat: int, name: String, kind: String, difficulty := "normal",
		connected := true, autoplay := false) -> Dictionary:
	return {
		"seat": seat, "name": name, "kind": kind, "difficulty": difficulty,
		"connected": connected, "autoplay": autoplay,
	}


## The same view with the table's clocks stamped on it.
func with_clock(server_time: int, turn_deadline := 0, hand_advance := 0) -> GameView:
	var v := GameView.from_dict(to_dict())
	v.server_time_ms = server_time
	v.turn_deadline_ms = turn_deadline
	v.hand_advance_ms = hand_advance
	return v


func to_dict() -> Dictionary:
	var d := {
		"phase": phase,
		"handIndex": hand_index,
		"handsPerGame": hands_per_game,
		"dealer": dealer,
		"turn": turn if turn >= 0 else null,
		"players": players.map(func(p): return (p as Dictionary).duplicate()),
		"you": you if you >= 0 else null,
		"hand": hand.duplicate(),
		"legalMoveIds": legal_move_ids.duplicate(),
		"handCounts": hand_counts.duplicate(),
		"bids": bids.map(func(b): return b if b >= 0 else null),
		"tricksWon": tricks_won.duplicate(),
		"trick": trick.map(func(p): return (p as Dictionary).duplicate()),
		"trickNumber": trick_number,
		"awaitingTrickClear": awaiting_trick_clear,
		"lastTrick": last_trick.duplicate(true) if not last_trick.is_empty() else null,
		"roundScores": round_scores.duplicate(true),
		"totals": totals.duplicate(),
		"rankings": rankings.duplicate(true),
	}
	if turn_deadline_ms > 0: d["turnDeadlineMs"] = turn_deadline_ms
	if hand_advance_ms > 0: d["handAdvanceMs"] = hand_advance_ms
	if server_time_ms > 0: d["serverTimeMs"] = server_time_ms
	if host_seat >= 0: d["hostSeat"] = host_seat
	return d


## Decodes a view. Total by design: a missing key falls back to a zero value
## and an unknown one is ignored, and every number is coerced from the floats
## Godot's JSON parser produces.
static func from_dict(d: Dictionary) -> GameView:
	var v := GameView.new()
	v.phase = str(d.get("phase", LOBBY))
	v.hand_index = _i(d.get("handIndex"))
	v.hands_per_game = _i(d.get("handsPerGame"), Rules.HANDS_PER_GAME)
	v.dealer = _i(d.get("dealer"))
	v.turn = _i(d.get("turn"), -1)
	v.players = []
	for p in _list(d.get("players")):
		if p is Dictionary:
			v.players.append(make_player(
				_i(p.get("seat")), str(p.get("name", "Player")), str(p.get("kind", "human")),
				str(p.get("difficulty", "normal")), bool(p.get("connected", true)),
				bool(p.get("autoplay", false))))
	v.you = _i(d.get("you"), -1)
	v.hand.assign(_list(d.get("hand")).map(func(c): return str(c)))
	v.legal_move_ids.assign(_list(d.get("legalMoveIds")).map(func(c): return str(c)))
	v.hand_counts.assign(_ints(d.get("handCounts"), 0))
	v.bids.assign(_ints(d.get("bids"), -1))
	v.tricks_won.assign(_ints(d.get("tricksWon"), 0))
	v.trick = _plays(d.get("trick"))
	v.trick_number = _i(d.get("trickNumber"))
	v.awaiting_trick_clear = bool(d.get("awaitingTrickClear", false))
	var lt = d.get("lastTrick")
	v.last_trick = {"plays": _plays(lt.get("plays")), "winner": _i(lt.get("winner"))} \
			if lt is Dictionary else {}
	v.round_scores = []
	for row in _list(d.get("roundScores")):
		v.round_scores.append(_list(row).map(func(x): return float(x) if x != null else 0.0))
	while v.round_scores.size() < 4:
		v.round_scores.append([])
	v.totals.assign(_list(d.get("totals")).map(func(x): return float(x) if x != null else 0.0))
	while v.totals.size() < 4:
		v.totals.append(0.0)
	v.rankings = []
	for r in _list(d.get("rankings")):
		if r is Dictionary:
			v.rankings.append({"seat": _i(r.get("seat")), "place": _i(r.get("place")),
					"total": float(r.get("total", 0.0))})
	v.turn_deadline_ms = _i(d.get("turnDeadlineMs"))
	v.hand_advance_ms = _i(d.get("handAdvanceMs"))
	v.server_time_ms = _i(d.get("serverTimeMs"))
	v.host_seat = _i(d.get("hostSeat"), -1)
	return v


static func _i(value, fallback := 0) -> int:
	if value is int or value is float:
		return int(value)
	return fallback


static func _list(value) -> Array:
	return value if value is Array else []


static func _ints(value, null_as: int) -> Array:
	var out := []
	for x in _list(value):
		out.append(int(x) if (x is int or x is float) else null_as)
	while out.size() < 4:
		out.append(null_as)
	return out


static func _plays(value) -> Array:
	var out := []
	for p in _list(value):
		if p is Dictionary:
			out.append(Cards.play(_i(p.get("seat")), str(p.get("card", ""))))
	return out
