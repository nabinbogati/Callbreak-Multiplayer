class_name GameSession
extends Node

## A seat at a Call Break table.
##
## The UI only ever talks to this interface, so a solo game against bots and a
## networked table look identical from the table's side: a redacted
## [GameView] to render, a stream of event dictionaries to animate, and a few
## intents to send. Networked play has states an offline game does not — a
## lobby, a countdown, reconnecting — which live here too with harmless
## defaults, so the table never has to ask which kind of session it holds.
##
## A session starts its work in [method _ready]; connect to its signals
## *before* adding it to the tree so the first deal is not missed.

## Anything about the session changed; re-read it.
signal changed
## A discrete happening — `{"event": "play", "seat": 1, "card": "AS"}` — for
## animation and sound. Names match the server's `event` frames.
signal game_event(event: Dictionary)

const CONNECTING := "connecting"
const READY := "ready"
const ERROR := "error"
const CLOSED := "closed"

## bots / private / online / lan
var mode := "bots"
var view: GameView
var status := CONNECTING
var error_message := ""

## When the seat on the clock runs out of time, on *this device's* monotonic
## clock (`Time.get_ticks_msec()`), or 0 when nothing is being timed.
var turn_deadline_ms := 0
## When the between-hands scoreboard deals the next hand on its own, on this
## device's clock, or 0.
var hand_advance_deadline_ms := 0


static func mode_label(m: String) -> String:
	match m:
		"private": return "Private"
		"online": return "vs Humans"
		"lan": return "LAN"
	return "vs Bots"


func is_ready() -> bool:
	return status == READY and view != null


## Whether this session talks to a network (lobby, reconnect UI, debug tools).
func is_network() -> bool:
	return false


## Tell the table this player is still here, cancelling any autoplay their
## silence caused. Cheap and harmless to repeat.
func wake_up() -> void:
	pass


func place_bid(_bid: int) -> void:
	pass


func play(_card: String) -> void:
	pass


## Leave the between-hands scoreboard and deal the next hand.
func continue_to_next_hand() -> void:
	pass


## Start a fresh game with the same seats.
func restart() -> void:
	pass


## Called by the table when the player leaves it for good.
func shutdown() -> void:
	queue_free()


# -------------------------------------------------- networked-table states

## The lobby while the table is still filling, normalised by
## [method parse_lobby]; empty once play begins.
func lobby() -> Dictionary:
	return {}


## Seconds until the table deals itself, or -1.
func countdown() -> int:
	return -1


func leave_lobby() -> void:
	pass


## Ask the table to deal. Only meaningful when `lobby().canStart`.
func start_game() -> void:
	pass


## Ask the room to change its match length while still in the lobby.
func set_hands_per_game(_hands: int) -> void:
	pass


## True while re-establishing a connection that dropped mid-game.
func is_resuming() -> bool:
	return false


func can_resume() -> bool:
	return false


## Try to reclaim a held seat right now.
func retry_now() -> void:
	pass


## Retry a first connect that outright failed.
func retry_connect() -> void:
	pass


## Debug-only: pretend this device's internet just dropped, or came back.
func simulate_offline(_offline: bool) -> void:
	pass


func is_simulated_offline() -> bool:
	return false


## Normalises a `lobby` frame (from the server or a LAN host).
static func parse_lobby(m: Dictionary) -> Dictionary:
	var seats := []
	for s in (m.get("seats") if m.get("seats") is Array else []):
		if s is Dictionary:
			seats.append({
				"seat": int(s.get("seat", 0)),
				"name": str(s.get("name", "Guest")),
				"isBot": s.get("kind") == "bot",
				"connected": bool(s.get("connected", true)),
				"isYou": bool(s.get("isYou", false)),
				"isHost": bool(s.get("isHost", false)),
			})
	return {
		"room": str(m.get("room", "")),
		"isOnline": m.get("mode") == "online",
		"seats": seats,
		"isHost": bool(m.get("isHost", false)),
		"canStart": bool(m.get("canStart", false)),
		"humansSeated": int(m.get("humansSeated", 0)),
		"minPlayers": int(m.get("minPlayers", 1)),
		"handsPerGame": int(m.get("handsPerGame", 5)),
	}


## Encodes an engine event as the wire frame the server would send.
static func event_frame(event: Dictionary) -> Dictionary:
	var frame := event.duplicate(true)
	frame["type"] = "event"
	return frame


## The table's pacing for the automatic parts of a hosted game. Slow enough to
## read, fast enough that a hand does not drag. Seconds, before the animation
## speed scale.
const BOT_THINK_MIN := 0.55
const BOT_THINK_EXTRA := 0.45
const TRICK_LINGER := 1.1
## How long a human seat has to bid on a LAN table before it is played for
## them. A solo game against bots is never hurried.
const BID_TIMEOUT := 5.0
## How long after a deal bidding opens. The deal view goes out the moment the
## cards are dealt, while the dealing animation ([constant Motion.DEAL_TOTAL])
## is still playing; until it is over no bot bids and no bid clock runs, so
## nobody's bid appears — or is hurried — mid-deal. Matches the server's
## `Pacing.DealGrace`.
const DEAL_GRACE := 3.5
## Play timeouts indexed by cards already down this trick: the leader thinks
## longest.
const PLAY_TIMEOUTS := [10.0, 8.0, 6.0, 5.0]
## How long the between-hands scoreboard waits before dealing anyway.
const HAND_ADVANCE_WAIT := 5.0
