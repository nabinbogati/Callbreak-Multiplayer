extends Node

## The on-disk queue of offline games waiting to reach the server (autoloaded
## as `Uploader`). Also owns the app's shared [ApiClient] as [member client].
##
## Everything here is fire-and-forget by construction: nothing on the gameplay
## path awaits it. A player who finishes a game on a train must not be shown a
## network error — the worst outcome of a failed upload is that the game shows
## up in their history later.
##
## `POST /v1/games` is idempotent on the `clientGameId` the recorder minted at
## kick-off, so the queue retries blindly: a payload that reached the server
## but whose response was lost comes back as a duplicate and is dropped.

const PATH := "user://upload_queue.json"
## Past this the queue has stopped being a retry buffer and started being a
## leak — the oldest entries go first.
const MAX_QUEUED := 50

var client: ApiClient
var _queue: Array = []
var _draining := false
var _persistent := true


func _ready() -> void:
	client = ApiClient.new()
	client.name = "ApiClient"
	client.identity = Settings.identity
	client.display_name_provider = func() -> String: return Settings.player_name
	client.origin_provider = func() -> String:
		return ApiClient.origin_from_socket_url(Settings.effective_server_url())
	add_child(client)
	# A successful call of any kind is the cheapest proof the network is back.
	client.server_reachable.connect(func(): drain())
	_load()
	# Games queued by the last run go out now — without making anything wait.
	drain.call_deferred()


## Drops the disk behind the queue — tests call this before enqueueing.
func use_memory_storage() -> void:
	_persistent = false
	_queue.clear()
	client.identity = Settings.identity


func pending() -> int:
	return _queue.size()


func pending_game_ids() -> Array:
	return _queue.map(func(p): return p.get("clientGameId", ""))


## Queues a finished offline game and starts trying to deliver it. Never blocks
## the caller on the network.
func enqueue(payload: Dictionary) -> void:
	if payload.is_empty():
		return
	_queue.append(payload)
	while _queue.size() > MAX_QUEUED:
		_queue.pop_front()
	_persist()
	drain()


## Delivers everything queued, in order, stopping at the first entry that
## failed for a reason a retry could fix.
func drain() -> void:
	if _draining or _queue.is_empty():
		return
	_draining = true
	while not _queue.is_empty():
		var payload: Dictionary = _queue[0]
		var res: Dictionary = await client.upload_game(payload)
		if not res["ok"]:
			var error: ApiClient.ApiError = res["error"]
			# Transient — no network, a timeout, a 5xx, a rate limit. Keep it and
			# stop: the next launch or the next successful call tries again.
			if error.is_transient():
				break
			# A 4xx says the payload itself is wrong; retrying cannot fix it.
		# Any 2xx drops the entry; `duplicate` is advisory and deliberately not
		# read, or the queue would re-send forever once the server said so.
		_queue.pop_front()
		_persist()
	_draining = false


func _persist() -> void:
	if not _persistent:
		return
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_queue))


func _load() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var parsed = Wire.parse_json(FileAccess.get_file_as_string(PATH))
	if parsed is Array:
		# Anything unreadable was written by a build whose payload shape is
		# gone; it can never be delivered, so it is dropped here.
		_queue = parsed.filter(func(p): return p is Dictionary and p.has("clientGameId"))
