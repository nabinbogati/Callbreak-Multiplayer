class_name IdentityStore
extends RefCounted

## Everything about "who this player is" that has to outlive the process.
##
## The device id is the load-bearing value: `POST /v1/auth/device` resolves it
## to a `users` row, so it is the account's only anchor until a Google/Apple
## login is linked to it (backend/docs/PERSISTENCE.md §1.2). Regenerating it
## would orphan every game and every statistic the player has — hence
## [member device_id] is written exactly once, on first launch, and only ever
## read afterwards.

const PATH := "user://identity.cfg"
const SECTION := "identity"

var _cfg := ConfigFile.new()
var _path: String
var _persistent: bool

var device_id: String


## Opens the on-disk store, minting the device id if this is a first launch.
## Pass `persistent = false` for a store with no disk behind it — what tests
## want.
func _init(persistent := true, path := PATH) -> void:
	_persistent = persistent
	_path = path
	if _persistent:
		_cfg.load(_path)
	device_id = str(_cfg.get_value(SECTION, "deviceId", ""))
	if device_id.is_empty():
		# A uuid minus its hyphens is 32 chars — inside the 8–128
		# `[A-Za-z0-9_-]` window `POST /v1/auth/device` enforces.
		device_id = IdentityStore.uuid_v4().replace("-", "")
		_put("deviceId", device_id)


## A random RFC 4122 version-4 uuid, lower-case and hyphenated, from the
## platform's CSPRNG — two ids that collide would silently merge two games on
## the server.
static func uuid_v4() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
			hex.substr(16, 4), hex.substr(20, 12)]


# ---------------------------------------------------------------- session

## The bearer token for `/v1`, or "" before the first `auth/device` call.
var session_token: String:
	get: return str(_cfg.get_value(SECTION, "sessionToken", ""))

## Unix seconds, or 0 when unknown.
var session_expires_at: int:
	get: return int(_cfg.get_value(SECTION, "sessionExpiresAt", 0))


## Whether the session is missing or close enough to expiry to be worth
## re-minting. The minute of slack keeps a token from dying mid-request.
func needs_session() -> bool:
	if session_token.is_empty():
		return true
	var expiry := session_expires_at
	return expiry > 0 and expiry < int(Time.get_unix_time_from_system()) + 60


func save_session(token: String, expires_at_unix := 0, user := {}) -> void:
	_cfg.set_value(SECTION, "sessionToken", token)
	if expires_at_unix > 0:
		_cfg.set_value(SECTION, "sessionExpiresAt", expires_at_unix)
	if not user.is_empty():
		_cfg.set_value(SECTION, "user", JSON.stringify(user))
	_flush()


## Forgets the session but keeps the device id, so the next call to
## `auth/device` lands back on the same account. There is deliberately no way
## to forget the device id.
func clear_session() -> void:
	_remove("sessionToken")
	_remove("sessionExpiresAt")


# ------------------------------------------------------------------ user

## The last profile the server sent, so the account tab can render before — or
## entirely without — a network round trip. Empty when none.
func cached_user() -> Dictionary:
	var parsed = _json("user")
	return parsed if parsed is Dictionary else {}


func save_user(user: Dictionary) -> void:
	_put("user", JSON.stringify(user))


# ------------------------------------------------------------ guest token

## The signed guest identity the *socket* gateway issues on join. Distinct from
## [member session_token], the REST credential.
var guest_token: String:
	get: return str(_cfg.get_value(SECTION, "guestToken", ""))
	set(value):
		if value.is_empty() or value == guest_token:
			return
		_put("guestToken", value)


# ----------------------------------------------------------- active game

## The networked table this player was last seated at, if it might still be
## running: `{serverUrl, roomCode, mode, resumeToken, playerName}`. Written on
## every `joined`/reconnect and cleared the moment the table is left or
## finishes. Surviving a restart is the whole point — a process the OS killed
## never got to say goodbye, so this is the only way to offer the seat back.
func active_game() -> Dictionary:
	var parsed = _json("activeGame")
	if parsed is Dictionary and parsed.has("serverUrl") and parsed.has("roomCode") \
			and parsed.has("resumeToken"):
		return parsed
	return {}


func save_active_game(game: Dictionary) -> void:
	_put("activeGame", JSON.stringify(game))


func clear_active_game() -> void:
	_remove("activeGame")


# ----------------------------------------------------- abandoned account

## The guest account a restore left behind, still carrying games nobody has
## decided on yet: `{accountId, games}`, or empty.
func pending_abandoned() -> Dictionary:
	var parsed = _json("pendingAbandoned")
	return parsed if parsed is Dictionary else {}


func save_pending_abandoned(abandoned: Dictionary) -> void:
	if abandoned.is_empty():
		_remove("pendingAbandoned")
	else:
		_put("pendingAbandoned", JSON.stringify(abandoned))


# -------------------------------------------------------------- plumbing

## A stored JSON value, or null when absent or unreadable (written by an older
## build — not worth a crash).
func _json(key: String):
	var raw := str(_cfg.get_value(SECTION, key, ""))
	if raw.is_empty():
		return null
	var json := JSON.new()
	return json.data if json.parse(raw) == OK else null


func _put(key: String, value) -> void:
	_cfg.set_value(SECTION, key, value)
	_flush()


func _remove(key: String) -> void:
	if _cfg.has_section_key(SECTION, key):
		_cfg.erase_section_key(SECTION, key)
	_flush()


func _flush() -> void:
	if _persistent:
		# A failed write costs this player their history on the next
		# reinstall. It must not cost them the game they are in the middle of.
		_cfg.save(_path)
