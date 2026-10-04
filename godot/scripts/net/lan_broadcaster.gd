class_name LanBroadcaster
extends Node

## Host side of LAN discovery: broadcasts this table once a second so
## [LanDiscovery] listeners on the same network can find it, until freed.

const INTERVAL := 1.0

var room_code: String
var host_name: String
var ws_port: int
var player_count := 1

var _udp := PacketPeerUDP.new()
var _left := 0.0
## Where adverts go. Overridable so tests can stay on loopback.
var target_address := "255.255.255.255"


func _init(room: String, host: String, port: int) -> void:
	room_code = room
	host_name = host
	ws_port = port


func _ready() -> void:
	_udp.set_broadcast_enabled(true)
	_send_once()


func _process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		_send_once()


func _send_once() -> void:
	_left = INTERVAL
	var payload := JSON.stringify({
		"type": "callbreak-lan", "room": room_code, "host": host_name,
		"port": ws_port, "players": player_count,
	}).to_utf8_buffer()
	_udp.set_dest_address(target_address, LanDiscovery.PORT)
	_udp.put_packet(payload)


func _exit_tree() -> void:
	_udp.close()
