class_name RemoteSession
extends GameSession

## A seat at a table hosted elsewhere — the game server, or a LAN host phone.
##
## The host holds the same engine and is the only authority on it, so the wire
## stays thin: the client sends intents and renders the redacted view it gets
## back. Beyond gameplay this carries the states an offline game has no need
## for — a lobby, a matchmaking countdown, and reconnecting to a held seat
## after the network drops.

## Protocol revision this client speaks. See backend/internal/protocol.
const PROTOCOL_VERSION := 2
## The room code that asks the server for matchmaking instead of a table.
const QUICKPLAY_ROOM := "QUICKPLAY"
const CONNECT_TIMEOUT := 8.0
## App-level keepalive. A network switch can leave a TCP connection silent
## with no FIN or RST ever arriving; without this the table would sit frozen.
const PING_INTERVAL := 10.0
const SILENCE_LIMIT := 25.0

const _REACHABILITY_HINT := "Check your internet connection and try again."
const _UNREACHABLE := "We couldn't reach the game server. " + _REACHABILITY_HINT
const _TIMED_OUT := "The game server is taking too long to respond. " + _REACHABILITY_HINT

var server_url: String
var room_code: String
var player_name: String
var difficulty := "normal"
## 3 or 5 for Online/Private, where the server deals on the creator's word; 0
## for LAN guests and joins, who inherit the host's length.
var hands_per_game := 0
## True when this join opens a brand-new private room.
var creating := false
## Anchors the player's account so the server attributes this seat's games.
var device_id := ""
## Identity from a previous session; keeps the same player id across tables.
var guest_token := ""
## Reissued on every join; presenting it after a drop reclaims this seat.
var resume_token := ""
## Whether this session was opened to reclaim a seat in a game under way.
var opened_to_resume := false
var seat := -1

var _ws: WsClient
var _socket_open := false
var _connect_started_ms := 0
var _last_inbound_ms := 0
var _ping_left := PING_INTERVAL
var _left := false
var _resuming := false
var _lobby := {}
var _countdown := -1
var _countdown_left := 0.0
var _turn_deadline_server := 0
var _hand_advance_server := 0
var _reconnect_grace_ms := 120000
## Local ticks at which the server gives this seat away; 0 when not held.
var _seat_held_until := 0
var _attempts := 0
var _retry_at := 0
var _simulated_offline := false


func _init(url := "", room := "", name_in := "You", mode_in := "online") -> void:
	server_url = url
	room_code = room
	player_name = name_in
	mode = mode_in


func _ready() -> void:
	opened_to_resume = not resume_token.is_empty()
	_connect()


func is_network() -> bool:
	return true


func lobby() -> Dictionary:
	return _lobby


func countdown() -> int:
	return _countdown


func is_resuming() -> bool:
	return _resuming


func is_simulated_offline() -> bool:
	return _simulated_offline


func can_resume() -> bool:
	return not resume_token.is_empty() and not _left and _seat_held_until > 0 \
			and Time.get_ticks_msec() < _seat_held_until and view != null \
			and view.phase != GameView.GAME_OVER


func seat_held_for_ms() -> int:
	return maxi(0, _seat_held_until - Time.get_ticks_msec()) if _seat_held_until > 0 else 0


# ------------------------------------------------------------ connection

func _connect() -> void:
	if _ws != null:
		return
	if _simulated_offline:
		_connect_failed("You're offline — the debug \"Go offline\" toggle is on. Turn it back on to connect.")
		return
	# The room rides in the query string too, so a load balancer can hash on
	# it and land everyone at a table on the same node.
	var url := server_url
	url += ("&" if url.contains("?") else "?") + "room=" + room_code.uri_encode()
	if OS.is_debug_build():
		print("[callbreak] connecting to %s (room %s, %s)" % [url, room_code, mode])
	_ws = WsClient.new()
	_socket_open = false
	var err := _ws.connect_to_url(url)
	if err != OK:
		_ws = null
		_log_failure("%s — error %d" % [url, err])
		_connect_failed(_UNREACHABLE)
		return
	_connect_started_ms = Time.get_ticks_msec()


func _process(delta: float) -> void:
	_tick_countdown(delta)
	if _retry_at > 0 and Time.get_ticks_msec() >= _retry_at:
		_retry_at = 0
		if status != CLOSED and not _left:
			_connect()
	if _ws == null:
		return
	var messages := _ws.poll()
	if _ws.state == WsClient.State.OPEN and not _socket_open:
		_socket_open = true
		_last_inbound_ms = Time.get_ticks_msec()
		_ping_left = PING_INTERVAL
		_send_join()
	# Frames that arrived together with a close are handled first: the server
	# sends its fatal error ("That room is full.") right before hanging up.
	for raw in messages:
		_last_inbound_ms = Time.get_ticks_msec()
		_on_message(raw)
		if _ws == null:
			return
	match _ws.state:
		WsClient.State.CONNECTING:
			if Time.get_ticks_msec() - _connect_started_ms > CONNECT_TIMEOUT * 1000:
				_drop_socket()
				_log_failure("%s took too long to answer." % server_url)
				_connect_failed(_TIMED_OUT)
		WsClient.State.OPEN:
			_ping_left -= delta
			if _ping_left <= 0.0:
				_ping_left = PING_INTERVAL
				_send({"type": "ping", "t": Time.get_ticks_msec()})
			if Time.get_ticks_msec() - _last_inbound_ms > SILENCE_LIMIT * 1000:
				# Gone silent: treat it exactly like a drop.
				_drop_socket()
				_on_disconnected()
		WsClient.State.CLOSED:
			var was_open := _socket_open
			var reason := _ws.close_reason
			_ws = null
			_socket_open = false
			if was_open:
				_on_disconnected()
			else:
				_log_failure("%s — %s" % [server_url, reason])
				_connect_failed(_UNREACHABLE)


func _send_join() -> void:
	var join := {
		"type": "join", "v": PROTOCOL_VERSION, "room": room_code,
		"mode": "online" if mode == "online" else "private",
		"name": player_name, "difficulty": difficulty,
	}
	if not guest_token.is_empty(): join["guestToken"] = guest_token
	if not device_id.is_empty(): join["deviceId"] = device_id
	if not resume_token.is_empty(): join["resumeToken"] = resume_token
	if hands_per_game > 0: join["handsPerGame"] = hands_per_game
	if creating: join["create"] = true
	_send(join)


func _log_failure(detail: String) -> void:
	if OS.is_debug_build():
		print("[callbreak] connect failed: ", detail)


## A connection attempt failed. While a seat is held that is a setback, not
## the end: keep trying until the grace window actually runs out.
func _connect_failed(message: String) -> void:
	if can_resume():
		_schedule_reconnect()
		return
	_fail(message)


## The socket closed without a fatal error frame: the network dropped rather
## than the server turning us away.
func _on_disconnected() -> void:
	if status == ERROR:
		return
	if _left:
		status = CLOSED
		changed.emit()
		return
	# Only a table that was actually dealt is worth reconnecting to. Rejoining
	# a lobby you walked away from would take a seat off whoever is waiting.
	if not resume_token.is_empty() and view != null and view.phase != GameView.GAME_OVER:
		if _seat_held_until == 0:
			_seat_held_until = Time.get_ticks_msec() + _reconnect_grace_ms
		_schedule_reconnect()
		return
	status = CLOSED
	changed.emit()


## Queues the next attempt: 1s, 2s, 4s, then every 8s — fast enough to catch a
## blip, slow enough not to spam a server that is genuinely gone.
func _schedule_reconnect() -> void:
	if not can_resume():
		_resuming = false
		_fail("We couldn't get you back in time, so your seat was given to another player. Start a new table to play again.")
		return
	_resuming = true
	status = CONNECTING
	changed.emit()
	var backoff: int = [1, 2, 4][_attempts] if _attempts < 3 else 8
	_attempts += 1
	_retry_at = Time.get_ticks_msec() + backoff * 1000


func retry_now() -> void:
	if not can_resume():
		return
	_retry_at = 0
	_attempts = 0
	error_message = ""
	_resuming = true
	status = CONNECTING
	changed.emit()
	_connect()


func retry_connect() -> void:
	if status != ERROR or _ws != null:
		return
	error_message = ""
	status = CONNECTING
	changed.emit()
	_connect()


func simulate_offline(offline: bool) -> void:
	if _simulated_offline == offline:
		return
	_simulated_offline = offline
	if offline and _ws != null:
		_retry_at = 0
		_drop_socket()
		_on_disconnected()
		return
	if not offline and can_resume():
		retry_now()
		return
	changed.emit()


func _drop_socket() -> void:
	if _ws != null:
		_ws.abort()
	_ws = null
	_socket_open = false


# --------------------------------------------------------------- frames

func _on_message(raw: String) -> void:
	var message = Wire.parse_json(raw)
	if not message is Dictionary:
		return
	match message.get("type"):
		"joined":
			seat = int(message.get("seat", -1)) if message.get("seat") != null else -1
			if message.get("guestToken") is String:
				guest_token = message["guestToken"]
			if message.get("resumeToken") is String:
				resume_token = message["resumeToken"]
			var grace = message.get("reconnectGraceMs")
			if (grace is float or grace is int) and grace > 0:
				_reconnect_grace_ms = int(grace)
			_resuming = false
			_attempts = 0
			_seat_held_until = 0
			_retry_at = 0
			status = READY
			changed.emit()
		"lobby":
			if message.get("started") == true:
				_lobby = {}
			else:
				_lobby = GameSession.parse_lobby(message)
				# A live lobby means play has not begun — or a reconnect landed
				# in a fresh match. A leftover view would render a stale table.
				view = null
				_countdown = -1
			status = READY
			changed.emit()
		"view":
			view = GameView.from_dict(message)
			_sync_deadlines(view)
			_lobby = {}
			_countdown = -1
			status = READY
			changed.emit()
		"event":
			_on_event(message)
		"error":
			_on_error(message)


## Converts the view's server-clock deadlines to this device's clock, using
## only the difference between two server timestamps — a phone whose clock is
## minutes off still counts down correctly. A view that merely restates a
## deadline does not re-anchor it.
func _sync_deadlines(v: GameView) -> void:
	if v.turn_deadline_ms != _turn_deadline_server:
		_turn_deadline_server = v.turn_deadline_ms
		turn_deadline_ms = _local_deadline(v, v.turn_deadline_ms)
	if v.hand_advance_ms != _hand_advance_server:
		_hand_advance_server = v.hand_advance_ms
		hand_advance_deadline_ms = _local_deadline(v, v.hand_advance_ms)


func _local_deadline(v: GameView, deadline: int) -> int:
	if deadline <= 0 or v.server_time_ms <= 0:
		return 0
	return Time.get_ticks_msec() + (deadline - v.server_time_ms)


func _on_event(message: Dictionary) -> void:
	var event := str(message.get("event", ""))
	match event:
		"countdown":
			# A retraction: somebody left and the deal that was coming is off.
			if message.get("cancelled") == true:
				_countdown = -1
			else:
				_countdown = int(message.get("seconds", 0))
				_countdown_left = 1.0
				if _countdown <= 0:
					_countdown = -1
			changed.emit()
			return
		"readyState":
			changed.emit()
			return
	var decoded := message.duplicate(true)
	decoded.erase("type")
	for key in ["seat", "bid", "handIndex"]:
		if decoded.get(key) is float:
			decoded[key] = int(decoded[key])
	if event == "seatChanged":
		decoded["name"] = str(message.get("name", "A player"))
	if event == "autoplay":
		decoded["name"] = str(message.get("name", "A player"))
	game_event.emit(decoded)
	if event == "seatChanged" or event == "autoplay":
		changed.emit()


func _tick_countdown(delta: float) -> void:
	if _countdown <= 0:
		return
	_countdown_left -= delta
	if _countdown_left <= 0.0:
		_countdown_left = 1.0
		_countdown -= 1
		if _countdown <= 0:
			_countdown = -1
		changed.emit()


func _on_error(message: Dictionary) -> void:
	var text := str(message.get("message", "The server rejected the request."))
	if message.get("code") == "redirect":
		# The table lives on another node; the client is simply pointed there.
		error_message = text + " Please reconnect."
		status = ERROR
		changed.emit()
		return
	# Non-fatal errors are corrections (an out-of-turn tap); the server sends a
	# fresh view straight after, so there is nothing to show.
	if message.get("fatal") != true:
		return
	_fail(text)


func _fail(message: String) -> void:
	error_message = message
	status = ERROR
	_resuming = false
	changed.emit()


func _send(message: Dictionary) -> void:
	if _ws != null and _ws.state == WsClient.State.OPEN:
		_ws.send_text(JSON.stringify(message))


# ------------------------------------------------------------ UI intents

func start_game() -> void:
	_send({"type": "start"})


func set_hands_per_game(hands: int) -> void:
	_send({"type": "hands", "hands": hands})


func leave_lobby() -> void:
	if _left:
		return
	_left = true
	_send({"type": "leave"})
	status = CLOSED
	changed.emit()


## A sign of life; takes the seat back off autoplay.
func wake_up() -> void:
	_send({"type": "awake"})


func place_bid(bid: int) -> void:
	_send({"type": "bid", "bid": bid})


func play(card: String) -> void:
	_send({"type": "play", "card": card})


func continue_to_next_hand() -> void:
	_send({"type": "next"})


func restart() -> void:
	_send({"type": "restart"})


## Gives up the seat deliberately rather than leaving a bot to play it out.
func shutdown() -> void:
	if not _left:
		_send({"type": "leave"})
	_left = true
	_retry_at = 0
	if _ws != null:
		_ws.close()
	status = CLOSED
	changed.emit()
	queue_free()
