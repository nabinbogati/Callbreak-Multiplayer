class_name WsClient
extends RefCounted

## A minimal RFC 6455 WebSocket client over [StreamPeerTCP] / [StreamPeerTLS].
##
## Why not [WebSocketPeer]: when a close frame arrives in the same read as the
## frame before it, WebSocketPeer (4.3 through 4.5) clears its receive buffer
## and the earlier frame is lost. The game server always sends its fatal error
## — "That room code is not valid.", "That room is full." — immediately before
## closing, so with WebSocketPeer the player would only ever see a generic
## "couldn't reach the server". This client keeps every frame that arrived.
##
## Text frames only (that is all the protocol uses), with fragmentation, ping
## replies and the close handshake. Call [method poll] every frame; it returns
## the messages that completed since the last call.

enum State { CONNECTING, OPEN, CLOSING, CLOSED }

const _GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
const _MAX_MESSAGE := 1 << 20

var state: int = State.CLOSED
var close_code := -1
var close_reason := ""

var _tcp: StreamPeerTCP
var _tls: StreamPeerTLS
var _stream: StreamPeer
var _host := ""
var _port := 0
var _path := "/"
var _secure := false
var _key := ""
var _handshake_sent := false
var _handshake_done := false
var _in := PackedByteArray()
var _fragments := PackedByteArray()
var _out := PackedByteArray()
var _resolve_id := -1


## Starts connecting. Returns an error for a URL that cannot be parsed.
func connect_to_url(url: String) -> int:
	var parsed := WsClient.parse_url(url)
	if parsed.is_empty():
		return ERR_INVALID_PARAMETER
	_secure = parsed["secure"]
	_host = parsed["host"]
	_port = parsed["port"]
	_path = parsed["path"]
	state = State.CONNECTING
	if _host.is_valid_ip_address():
		return _open_tcp(_host)
	# Resolved off the main thread so a slow DNS server never freezes the UI.
	_resolve_id = IP.resolve_hostname_queue_item(_host, IP.TYPE_ANY)
	return OK


func _open_tcp(ip: String) -> int:
	_tcp = StreamPeerTCP.new()
	var err := _tcp.connect_to_host(ip, _port)
	if err != OK:
		_finish(1006, "connect failed")
		return err
	_stream = _tcp
	return OK


## `{secure, host, port, path}` for a ws:// or wss:// URL, or empty.
static func parse_url(url: String) -> Dictionary:
	var u := url.strip_edges()
	var secure := false
	if u.begins_with("wss://"):
		secure = true
		u = u.substr(6)
	elif u.begins_with("ws://"):
		u = u.substr(5)
	else:
		return {}
	var path_at := u.find("/")
	var query_at := u.find("?")
	var split := path_at
	if split < 0 or (query_at >= 0 and query_at < split):
		split = query_at
	var authority := u if split < 0 else u.substr(0, split)
	var path := "/" if split < 0 else u.substr(split)
	if path.begins_with("?"):
		path = "/" + path
	var host := authority
	var port := 443 if secure else 80
	if authority.begins_with("["):
		var end := authority.find("]")
		if end < 0:
			return {}
		host = authority.substr(1, end - 1)
		if authority.length() > end + 2 and authority[end + 1] == ":":
			port = int(authority.substr(end + 2))
	elif authority.contains(":"):
		host = authority.get_slice(":", 0)
		port = int(authority.get_slice(":", 1))
	if host.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"secure": secure, "host": host, "port": port, "path": path}


## Advances the connection. Returns the text messages completed since the last
## call — including any that arrived alongside a close.
func poll() -> Array[String]:
	var messages: Array[String] = []
	if state == State.CLOSED:
		return messages
	if _resolve_id >= 0:
		match IP.get_resolve_item_status(_resolve_id):
			IP.RESOLVER_STATUS_WAITING:
				return messages
			IP.RESOLVER_STATUS_DONE:
				var ip := IP.get_resolve_item_address(_resolve_id)
				IP.erase_resolve_item(_resolve_id)
				_resolve_id = -1
				if ip.is_empty() or _open_tcp(ip) != OK:
					_finish(1006, "could not resolve " + _host)
				return messages
			_:
				IP.erase_resolve_item(_resolve_id)
				_resolve_id = -1
				_finish(1006, "could not resolve " + _host)
				return messages
	if _tcp == null:
		return messages
	_tcp.poll()
	var tcp_status := _tcp.get_status()
	if tcp_status == StreamPeerTCP.STATUS_ERROR:
		_finish(1006, "connection error")
		return messages
	if tcp_status == StreamPeerTCP.STATUS_CONNECTING:
		return messages
	if tcp_status == StreamPeerTCP.STATUS_NONE:
		_drain_into(messages)
		_finish(1006, "connection lost")
		return messages

	if _secure and _tls == null:
		_tls = StreamPeerTLS.new()
		if _tls.connect_to_stream(_tcp, _host, TLSOptions.client()) != OK:
			_finish(1015, "TLS failed")
			return messages
		_stream = _tls
	if _tls != null:
		_tls.poll()
		var tls_status := _tls.get_status()
		if tls_status == StreamPeerTLS.STATUS_HANDSHAKING:
			return messages
		if tls_status != StreamPeerTLS.STATUS_CONNECTED:
			_drain_into(messages)
			_finish(1015 if not _handshake_done else 1006, "TLS closed")
			return messages

	if not _handshake_sent:
		_send_handshake()

	_read_available()
	if not _handshake_done:
		if not _finish_handshake():
			return messages
	_drain_into(messages)
	_flush()
	return messages


func send_text(text: String) -> void:
	if state != State.OPEN:
		return
	_queue_frame(0x1, text.to_utf8_buffer())
	_flush()


## Starts the close handshake; the state reaches CLOSED once the server answers
## or the socket goes away.
func close(code := 1000, reason := "") -> void:
	if state == State.CONNECTING or not _handshake_done:
		_finish(code, reason)
		return
	if state != State.OPEN:
		return
	var payload := PackedByteArray([code >> 8, code & 0xff])
	payload.append_array(reason.to_utf8_buffer())
	_queue_frame(0x8, payload)
	_flush()
	state = State.CLOSING


## Drops the connection immediately, without a handshake.
func abort() -> void:
	_finish(1006, "aborted")


# --------------------------------------------------------------- handshake

func _send_handshake() -> void:
	_handshake_sent = true
	_key = Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(16))
	var host_header := _host if (_port == (443 if _secure else 80)) else "%s:%d" % [_host, _port]
	var request := "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nUser-Agent: CallBreak-Godot\r\n\r\n" % [_path, host_header, _key]
	_out.append_array(request.to_utf8_buffer())
	_flush()


func _finish_handshake() -> bool:
	var end := _find_header_end()
	if end < 0:
		if _in.size() > 16384:
			_finish(1002, "handshake too large")
		return false
	var head := _in.slice(0, end).get_string_from_utf8()
	_in = _in.slice(end + 4)
	var lines := head.split("\r\n")
	if lines.is_empty() or not lines[0].contains(" 101"):
		_finish(1002, "upgrade refused: " + (lines[0] if not lines.is_empty() else ""))
		return false
	var accept := ""
	for line in lines:
		var colon := line.find(":")
		if colon > 0 and line.substr(0, colon).strip_edges().to_lower() == "sec-websocket-accept":
			accept = line.substr(colon + 1).strip_edges()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update((_key + _GUID).to_utf8_buffer())
	if accept != Marshalls.raw_to_base64(ctx.finish()):
		_finish(1002, "bad Sec-WebSocket-Accept")
		return false
	_handshake_done = true
	state = State.OPEN
	return true


func _find_header_end() -> int:
	for i in range(0, _in.size() - 3):
		if _in[i] == 13 and _in[i + 1] == 10 and _in[i + 2] == 13 and _in[i + 3] == 10:
			return i
	return -1


# ------------------------------------------------------------------ frames

func _read_available() -> void:
	while true:
		var available := _stream.get_available_bytes()
		if available <= 0:
			break
		var chunk: Array = _stream.get_partial_data(available)
		if chunk[0] != OK:
			break
		var bytes: PackedByteArray = chunk[1]
		if bytes.is_empty():
			break
		_in.append_array(bytes)


## Parses every complete frame in the buffer.
func _drain_into(messages: Array[String]) -> void:
	if not _handshake_done:
		return
	while true:
		if _in.size() < 2:
			return
		var b0 := _in[0]
		var b1 := _in[1]
		var fin := (b0 & 0x80) != 0
		var opcode := b0 & 0x0f
		var masked := (b1 & 0x80) != 0
		var length := b1 & 0x7f
		var offset := 2
		if length == 126:
			if _in.size() < 4:
				return
			length = (_in[2] << 8) | _in[3]
			offset = 4
		elif length == 127:
			if _in.size() < 10:
				return
			length = 0
			for i in 8:
				length = (length << 8) | _in[2 + i]
			offset = 10
		if length > _MAX_MESSAGE:
			_finish(1009, "message too big")
			return
		var mask := PackedByteArray()
		if masked:
			if _in.size() < offset + 4:
				return
			mask = _in.slice(offset, offset + 4)
			offset += 4
		if _in.size() < offset + length:
			return
		var payload := _in.slice(offset, offset + length)
		_in = _in.slice(offset + length)
		if masked:
			for i in payload.size():
				payload[i] = payload[i] ^ mask[i % 4]

		match opcode:
			0x0, 0x1, 0x2:
				_fragments.append_array(payload)
				if fin:
					if opcode != 0x2:
						messages.append(_fragments.get_string_from_utf8())
					_fragments = PackedByteArray()
			0x8:
				close_code = (payload[0] << 8) | payload[1] if payload.size() >= 2 else 1005
				close_reason = payload.slice(2).get_string_from_utf8() if payload.size() > 2 else ""
				if state == State.OPEN:
					# Echo the close, as the protocol requires, then hang up.
					_queue_frame(0x8, payload.slice(0, 2) if payload.size() >= 2 else PackedByteArray())
					_flush()
				_finish(close_code, close_reason)
				return
			0x9:
				_queue_frame(0xA, payload)
			0xA:
				pass


## Client frames are always masked.
func _queue_frame(opcode: int, payload: PackedByteArray) -> void:
	var header := PackedByteArray([0x80 | opcode])
	var n := payload.size()
	if n < 126:
		header.append(0x80 | n)
	elif n < 65536:
		header.append_array([0x80 | 126, (n >> 8) & 0xff, n & 0xff])
	else:
		header.append(0x80 | 127)
		for i in range(7, -1, -1):
			header.append((n >> (i * 8)) & 0xff)
	var mask := Crypto.new().generate_random_bytes(4)
	header.append_array(mask)
	var body := payload.duplicate()
	for i in body.size():
		body[i] = body[i] ^ mask[i % 4]
	_out.append_array(header)
	_out.append_array(body)


func _flush() -> void:
	if _out.is_empty() or _stream == null:
		return
	var result: Array = _stream.put_partial_data(_out)
	if result[0] == OK:
		_out = _out.slice(result[1])


func _finish(code: int, reason: String) -> void:
	if state == State.CLOSED:
		return
	if _resolve_id >= 0:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1
	if close_code < 0:
		close_code = code
		close_reason = reason
	state = State.CLOSED
	if _tls != null:
		_tls.disconnect_from_stream()
	if _tcp != null:
		_tcp.disconnect_from_host()
