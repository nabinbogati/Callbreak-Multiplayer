class_name LanDiscovery
extends Node

## Client side of LAN play: listens for [LanBroadcaster] packets and keeps a
## live list of the tables currently visible on this network, pruning any not
## seen for a few seconds.

signal games_changed

## Fixed UDP port both sides use. Plain broadcast (not multicast), so no extra
## Android multicast permission is needed.
const PORT := 47777
## How long an advert is trusted after its last sighting.
const ADVERT_TTL_MS := 4000

var _udp := PacketPeerUDP.new()
## `"ip:room"` → `{advert, seen_ms}`.
var _seen := {}
var _prune_left := 1.0


func _ready() -> void:
	_udp.set_broadcast_enabled(true)
	var err := _udp.bind(PORT)
	if err != OK:
		push_warning("LAN discovery could not bind UDP %d (error %d)" % [PORT, err])


## Currently-visible games, most recently seen first. Each
## `{roomCode, hostName, address, wsPort, playerCount, wsUrl}`.
func games() -> Array:
	var entries := _seen.values()
	entries.sort_custom(func(a, b): return a["seen_ms"] > b["seen_ms"])
	return entries.map(func(e): return e["advert"])


func _process(delta: float) -> void:
	while _udp.is_bound() and _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		_on_packet(data.get_string_from_utf8(), _udp.get_packet_ip())
	_prune_left -= delta
	if _prune_left <= 0.0:
		_prune_left = 1.0
		_prune()


func _on_packet(text: String, ip: String) -> void:
	var m = Wire.parse_json(text)
	if not m is Dictionary or m.get("type") != "callbreak-lan":
		return
	var room = m.get("room")
	var host = m.get("host")
	var port = m.get("port")
	if not room is String or not host is String or not (port is float or port is int) or ip.is_empty():
		return
	var advert := {
		"roomCode": room, "hostName": host, "address": ip, "wsPort": int(port),
		"playerCount": int(m.get("players", 1)), "maxPlayers": 4,
		"wsUrl": "ws://%s:%d" % [ip, int(port)],
	}
	_seen["%s:%s" % [ip, room]] = {"advert": advert, "seen_ms": Time.get_ticks_msec()}
	games_changed.emit()


func _prune() -> void:
	var cutoff := Time.get_ticks_msec() - ADVERT_TTL_MS
	var before := _seen.size()
	for key in _seen.keys():
		if _seen[key]["seen_ms"] < cutoff:
			_seen.erase(key)
	if _seen.size() != before:
		games_changed.emit()


func _exit_tree() -> void:
	_udp.close()
