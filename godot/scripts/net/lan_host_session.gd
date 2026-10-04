class_name LanHostSession
extends HostedSession

## A table hosted on this device, reachable by other phones on the same Wi‑Fi
## over a plain WebSocket server — no external infrastructure, no internet.
##
## The host occupies seat 0. There is a lobby phase (seats open, guests trickle
## in, found via [LanBroadcaster]) until the host calls [method start_game],
## which fills open seats with bots and deals. Guests connect with an ordinary
## [RemoteSession], so the frames sent here are shaped exactly like the game
## server's.
##
## Unlike a solo game it runs the table's clocks: a seat that does not bid or
## play in time is played for (see [method HostedSession._time_out_seat]), and
## the scoreboard deals on its own once its wait runs out.

const MIN_PLAYERS := 2

var room_code := ""
var _server := TCPServer.new()
var _broadcaster: LanBroadcaster
## Each `{"ws": WebSocketPeer, "seat": int}`; seat is -1 until it joins.
var _peers: Array = []


func _init(name_in := "You", room := "", difficulty_in := "normal", hands := Rules.HANDS_PER_GAME,
		scale := 1.0) -> void:
	super()
	mode = "lan"
	timed = true
	player_name = name_in
	room_code = room
	difficulty = difficulty_in
	hands_per_game = hands
	animation_scale = scale
	status = READY
	_seats[HOST_SEAT] = GameView.make_player(HOST_SEAT, player_name, "human")


## Binds the embedded WebSocket server on an ephemeral port and starts
## advertising the table. Returns the bind error, OK on success.
func start_hosting(port := 0) -> int:
	var err := _server.listen(port)
	if err != OK:
		status = ERROR
		error_message = "Couldn't open a table on this network. Check that Wi‑Fi is on and try again."
		changed.emit()
		return err
	_broadcaster = LanBroadcaster.new(room_code, player_name, _server.get_local_port())
	add_child(_broadcaster)
	changed.emit()
	return OK


func ws_port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0


func lobby_players() -> Array:
	return _seats.filter(func(p): return p != null)


## The host may start once the deal is waiting and at least one guest is
## connected — a host playing three bots is what the offline mode is for.
func can_start() -> bool:
	return not _started and lobby_players().filter(func(p): return p["connected"]).size() >= MIN_PLAYERS


func lobby() -> Dictionary:
	if _started:
		return {}
	var l := GameSession.parse_lobby(_lobby_frame(HOST_SEAT))
	l["canStart"] = can_start()
	return l


func start_game() -> void:
	if _started:
		return
	_deal_new_game()
	if _broadcaster != null:
		_broadcaster.queue_free()
		_broadcaster = null
	_publish()


func set_hands_per_game(hands: int) -> void:
	if _started or hands == hands_per_game:
		return
	hands_per_game = hands
	changed.emit()
	_fan_out_lobbies()


func leave_lobby() -> void:
	shutdown()


# ------------------------------------------------------------ networking

func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.accept_stream(_server.take_connection())
		_peers.append({"ws": ws, "seat": -1})

	for peer in _peers.duplicate():
		var ws: WebSocketPeer = peer["ws"]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				_on_frame(peer, ws.get_packet().get_string_from_utf8())
		elif state == WebSocketPeer.STATE_CLOSED:
			_peers.erase(peer)
			_on_peer_gone(peer)


func _on_frame(peer: Dictionary, raw: String) -> void:
	var message = Wire.parse_json(raw)
	if not message is Dictionary:
		return
	var seat: int = peer["seat"]
	match message.get("type"):
		"join":
			if seat >= 0:
				return
			if _started:
				_send(peer["ws"], {"type": "error", "message": "The game has already started.", "fatal": true})
				peer["ws"].close()
				return
			var open_seat := _next_open_seat()
			if open_seat < 0:
				_send(peer["ws"], {"type": "error", "message": "Room is full", "fatal": true})
				peer["ws"].close()
				return
			var name := str(message.get("name", "")).strip_edges()
			peer["seat"] = open_seat
			_seats[open_seat] = GameView.make_player(open_seat, name if not name.is_empty() else "Guest", "human")
			_send(peer["ws"], {"type": "joined", "seat": open_seat, "room": room_code})
			_update_advert()
			changed.emit()
			_fan_out_lobbies()
		"bid":
			if seat < 0 or not _started or not (message.get("bid") is float or message.get("bid") is int):
				return
			# Acting is proof enough of presence, so it also takes the seat back
			# off autoplay — even if the bid itself is rejected.
			var woke := _clear_autoplay(seat)
			if _game.place_bid(seat, int(message["bid"])) or woke:
				_publish()
		"play":
			if seat < 0 or not _started or not message.get("card") is String:
				return
			var woke := _clear_autoplay(seat)
			if _game.play_card(seat, message["card"]) or woke:
				_publish()
		"awake":
			if seat >= 0 and _started and _clear_autoplay(seat):
				_publish()
		"next":
			if seat >= 0:
				_next_from(seat)
		"restart":
			if _started:
				restart()
		"leave":
			peer["ws"].close()
		"ping":
			_send(peer["ws"], {"type": "pong", "serverTimeMs": int(Time.get_unix_time_from_system() * 1000)})


func _on_peer_gone(peer: Dictionary) -> void:
	var seat: int = peer["seat"]
	if seat < 0 or status == CLOSED:
		return
	var p = _seats[seat]
	if p != null:
		p["connected"] = false
		if _started:
			_game.set_player(seat, p)
			_announce({"event": "seatChanged", "seat": seat, "name": p["name"],
					"connected": false, "kind": p["kind"]})
		else:
			# Before the deal a guest who walks away frees the chair.
			_seats[seat] = null
	_update_advert()
	changed.emit()
	if _started:
		_publish()
	else:
		_fan_out_lobbies()


func _next_open_seat() -> int:
	for seat in range(1, 4):
		if _seats[seat] == null:
			return seat
	return -1


func _update_advert() -> void:
	if _broadcaster != null:
		_broadcaster.player_count = lobby_players().size()


func _send(ws: WebSocketPeer, message: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(message))


func _joined_peers() -> Array:
	return _peers.filter(func(p): return p["seat"] >= 0)


## The pre-game lobby as one seat sees it, shaped the way the server shapes
## it, so a guest's table renders the waiting lobby.
func _lobby_frame(for_seat: int) -> Dictionary:
	var seats := []
	for i in 4:
		var p = _seats[i]
		if p != null:
			seats.append({"seat": i, "name": p["name"], "kind": p["kind"], "connected": p["connected"],
					"isYou": i == for_seat, "isHost": i == HOST_SEAT})
	return {
		"type": "lobby", "room": room_code, "mode": "lan", "hostSeat": HOST_SEAT,
		"isHost": for_seat == HOST_SEAT, "canStart": false, "started": _started,
		"seats": seats,
		"humansSeated": lobby_players().filter(func(p): return p["connected"]).size(),
		"minPlayers": MIN_PLAYERS, "handsPerGame": hands_per_game,
	}


func _fan_out_lobbies() -> void:
	if _started:
		return
	for peer in _joined_peers():
		_send(peer["ws"], _lobby_frame(peer["seat"]))


func _broadcast_views() -> void:
	for peer in _joined_peers():
		var frame := _view_for(peer["seat"]).to_dict()
		frame["type"] = "view"
		_send(peer["ws"], frame)


func _announce(event: Dictionary) -> void:
	super(event)
	var frame := GameSession.event_frame(event)
	for peer in _joined_peers():
		_send(peer["ws"], frame)


func shutdown() -> void:
	status = CLOSED
	for peer in _peers:
		peer["ws"].close()
	_server.stop()
	super()
