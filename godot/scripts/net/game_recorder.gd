class_name GameRecorder
extends RefCounted

## Accumulates the `POST /v1/games` body while an offline game is played.
##
## `bots` and `lan` tables never touch the server (backend/docs/PERSISTENCE.md
## §2.2), so the device is the only thing that can put them in the player's
## history. The engine clears bids and tricks on every deal, so per-hand rows
## are snapshotted as each hand ends.
##
## [member client_game_id] is minted at construction — when the game starts,
## not when it finishes. That is the whole idempotency guarantee: every retry
## of a failed upload carries the id the server may already have seen.

var mode: String
## The seat this device plays. Exactly one seat is uploaded with `isYou: true`.
var you_seat: int
var client_game_id: String
var started_at: String

var _hands: Array = []
var _running: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _total_bid: Array[int] = [0, 0, 0, 0]
var _total_tricks: Array[int] = [0, 0, 0, 0]
var _hands_made: Array[int] = [0, 0, 0, 0]
var hands_recorded := 0


func _init(mode_in: String, you: int, game_id := "", started := "") -> void:
	mode = mode_in
	you_seat = you
	client_game_id = game_id if not game_id.is_empty() else IdentityStore.uuid_v4()
	started_at = started if not started.is_empty() else GameRecorder.now_iso()


static func now_iso() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"


## Only the two modes played entirely on the device may be uploaded.
func is_uploadable() -> bool:
	return mode == "bots" or mode == "lan"


## Snapshots one finished hand, while the engine still holds its bids and
## tricks — from the `handOver` event, before the next deal.
func record_hand(hand_index: int, bids: Array, tricks_won: Array, deltas: Array) -> void:
	hands_recorded += 1
	for seat in 4:
		var bid: int = max(0, bids[seat]) if seat < bids.size() else 0
		var tricks: int = tricks_won[seat] if seat < tricks_won.size() else 0
		var delta: float = deltas[seat] if seat < deltas.size() else 0.0
		# Rounded exactly the way the engine rounds its own totals.
		_running[seat] = Rules.round_tenth(_running[seat] + delta)
		_total_bid[seat] += bid
		_total_tricks[seat] += tricks
		if tricks >= bid:
			_hands_made[seat] += 1
		_hands.append({
			"handIndex": hand_index, "seat": seat, "bid": bid, "tricksWon": tricks,
			"scoreDelta": delta, "runningTotal": _running[seat],
		})


## The finished payload, or an empty dictionary when there is nothing worth
## uploading — an unsupported mode, or a table abandoned before any hand ended.
func build(players: Array, totals: Array, rankings: Array, hands_total: int, completed := true) -> Dictionary:
	if not is_uploadable() or _hands.is_empty():
		return {}
	var place_of := {}
	for r in rankings:
		place_of[int(r["seat"])] = int(r["place"])
	var seats := []
	for p in players:
		var seat: int = p["seat"]
		var row := {
			"seat": seat,
			"isYou": seat == you_seat,
			"displayName": p["name"],
			"isBot": GameView.is_bot(p),
			"finalScore": totals[seat] if seat < totals.size() else 0.0,
			"place": place_of.get(seat, 0),
			"totalBid": _total_bid[seat],
			"totalTricks": _total_tricks[seat],
			"handsMade": _hands_made[seat],
		}
		if GameView.is_bot(p):
			row["botDifficulty"] = p.get("difficulty", "normal")
		seats.append(row)
	return {
		"clientGameId": client_game_id,
		"mode": mode,
		"completed": completed,
		"handsTotal": hands_total,
		"startedAt": started_at,
		"finishedAt": GameRecorder.now_iso(),
		"seats": seats,
		"hands": _hands.duplicate(true),
	}
