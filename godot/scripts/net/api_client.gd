class_name ApiClient
extends Node

## Typed access to every endpoint in `backend/docs/API.md`.
##
## The client owns the session token end to end: it mints one from the device
## id on first use, persists it through [IdentityStore], and re-mints it once
## on a `401` before giving up. No caller has to think about auth.
##
## Every call is a coroutine returning `{"ok": bool, "data": Dictionary,
## "error": ApiError}` — exactly one thing to check, whether the server said no
## or the request never reached it.

## Emitted after any request the server answered successfully — the signal the
## upload queue drains on.
signal server_reachable
signal _auth_done

## Whether the Google/Facebook/Apple upgrade flow is live. Off, deliberately:
## `POST /v1/auth/link` answers 501 today.
const ACCOUNT_LINKING_ENABLED := false

var identity: IdentityStore
## Read at call time so an account is named whatever the player typed.
var display_name_provider: Callable = func() -> String: return "Player"
## The HTTP origin, e.g. `http://host:8080`. Recomputed per request from
## [member origin_provider] when set, so the debug server override applies to
## REST and the socket together.
var origin := ""
var origin_provider: Callable
## Seconds. A history screen that spins forever is worse than one that says it
## could not load and offers a retry.
var timeout := 12.0

var _authing := false


## A non-2xx answer from `/v1`, or a request that never got one.
class ApiError:
	extends RefCounted
	const NETWORK := "network"
	const TIMEOUT := "timeout"

	var code: String
	var message: String
	## HTTP status, or 0 when the request never completed.
	var status_code: int

	func _init(code_in: String, message_in := "", status := 0) -> void:
		code = code_in
		message = message_in
		status_code = status

	## The server has no database configured (503) — "history is off here".
	func is_persistence_disabled() -> bool:
		return code == "persistence_disabled"

	func is_unauthorized() -> bool:
		return code == "unauthorized" or status_code == 401

	func is_not_implemented() -> bool:
		return code == "not_implemented" or status_code == 501

	## Whether re-sending the identical request could plausibly succeed later.
	func is_transient() -> bool:
		return status_code == 0 or status_code == 429 or status_code >= 500

	## The server writes player-facing copy, so its own message wins.
	func display_message() -> String:
		if not message.is_empty():
			return message
		if code == NETWORK:
			return "No connection to the game server."
		if code == TIMEOUT:
			return "The server took too long to answer."
		if status_code >= 500:
			return "The server hit a snag. Please try again in a moment."
		if status_code == 429:
			return "A little too fast. Give it a moment, then try again."
		if status_code == 404:
			return "This server does not recognise that request — it may be an older version. Please try again."
		if status_code >= 400:
			return "That request did not go through. Check your input and try again."
		return "Something unexpected happened. Please try again."

	static func from_body(status: int, body: Dictionary) -> ApiError:
		var err = body.get("error")
		var fields: Dictionary = err if err is Dictionary else {}
		var c = fields.get("code")
		var m = fields.get("message")
		return ApiError.new(c if c is String and not c.is_empty() else "http_%d" % status,
				m if m is String else "", status)


## The HTTP origin behind a websocket URL: `wss://host/ws` → `https://host`.
## Any path prefix in front of the trailing `/ws` (a reverse proxy mounting the
## app under a subpath) is kept.
static func origin_from_socket_url(socket_url: String) -> String:
	var url := socket_url.strip_edges()
	var scheme_end := url.find("://")
	var scheme := url.substr(0, scheme_end).to_lower() if scheme_end >= 0 else ""
	var rest := url.substr(scheme_end + 3) if scheme_end >= 0 else url
	# Anything unrecognised is assumed secure: guessing http would silently
	# downgrade a production URL.
	var http_scheme := "http" if scheme == "ws" or scheme == "http" else "https"
	var q := rest.find("?")
	if q >= 0:
		rest = rest.substr(0, q)
	var slash := rest.find("/")
	var host := rest if slash < 0 else rest.substr(0, slash)
	var path := "" if slash < 0 else rest.substr(slash)
	var segments := Array(path.split("/", false))
	if not segments.is_empty() and segments.back() == "ws":
		segments.pop_back()
	var prefix := "" if segments.is_empty() else "/" + "/".join(segments)
	return "%s://%s%s" % [http_scheme, host, prefix]


# ----------------------------------------------------------------- auth

## Ensures a usable bearer token exists, minting one from the device id if
## not. Concurrent callers share one in-flight handshake.
func ensure_session() -> void:
	if not identity.needs_session():
		return
	if _authing:
		await _auth_done
		return
	_authing = true
	await authenticate_device()
	_authing = false
	_auth_done.emit()


## `POST /v1/auth/device` — the only unauthenticated endpoint.
func authenticate_device() -> Dictionary:
	var body := {"deviceId": identity.device_id, "displayName": display_name_provider.call()}
	var platform := _platform_name()
	if not platform.is_empty():
		body["platform"] = platform
	var res := await _send(HTTPClient.METHOD_POST, "/v1/auth/device", {}, body, false)
	if res["ok"]:
		_store_session(res["data"])
	return res


## `POST /v1/auth/restore` — re-anchors this install's device id onto the
## account whose id the player saved from their old device. `data.abandoned`
## is set when the replaced install still had games.
func restore_account(account_id: String) -> Dictionary:
	var res := await _send(HTTPClient.METHOD_POST, "/v1/auth/restore", {}, {"accountId": account_id})
	if res["ok"]:
		_store_session(res["data"])
	return res


## `POST /v1/me/merge/{id}` — folds the abandoned guest into this account.
func merge_abandoned(account_id: String) -> Dictionary:
	var res := await _send(HTTPClient.METHOD_POST, "/v1/me/merge/" + account_id.uri_encode())
	if res["ok"] and res["data"].get("user") is Dictionary:
		identity.save_user(res["data"]["user"])
	return res


## `DELETE /v1/me/abandoned/{id}` — leaves the abandoned guest's games behind.
func discard_abandoned(account_id: String) -> Dictionary:
	return await _send(HTTPClient.METHOD_DELETE, "/v1/me/abandoned/" + account_id.uri_encode())


func _store_session(body: Dictionary) -> void:
	var token = body.get("token")
	if token is String and not token.is_empty():
		var expires := 0
		var stamp = body.get("expiresAt")
		if stamp is String and not stamp.is_empty():
			expires = Wire.parse_iso(stamp)
		var user = body.get("user")
		identity.save_session(token, expires, user if user is Dictionary else {})


# ------------------------------------------------------------------- me

## `GET /v1/me`.
func fetch_me() -> Dictionary:
	var res := await _send(HTTPClient.METHOD_GET, "/v1/me")
	if res["ok"] and res["data"].get("user") is Dictionary:
		identity.save_user(res["data"]["user"])
	return res


## `PATCH /v1/me`.
func update_display_name(name: String) -> Dictionary:
	var res := await _send(HTTPClient.METHOD_PATCH, "/v1/me", {}, {"displayName": name})
	if res["ok"] and res["data"].get("user") is Dictionary:
		identity.save_user(res["data"]["user"])
	return res


## `GET /v1/me/stats` — every scope in one response.
func fetch_stats() -> Dictionary:
	return await _send(HTTPClient.METHOD_GET, "/v1/me/stats")


## `GET /v1/me/games?mode=&limit=&cursor=`.
func fetch_games(mode := "", limit := 0, cursor := "") -> Dictionary:
	var query := {}
	if not mode.is_empty(): query["mode"] = mode
	if limit > 0: query["limit"] = str(limit)
	if not cursor.is_empty(): query["cursor"] = cursor
	return await _send(HTTPClient.METHOD_GET, "/v1/me/games", query)


## `GET /v1/games/{id}` — the summary plus its hand-by-hand scoreboard.
func fetch_game(id: String) -> Dictionary:
	return await _send(HTTPClient.METHOD_GET, "/v1/games/" + id.uri_encode())


## `POST /v1/games` — idempotent on `clientGameId`.
func upload_game(payload: Dictionary) -> Dictionary:
	return await _send(HTTPClient.METHOD_POST, "/v1/games", {}, payload)


# -------------------------------------------------------------- plumbing

func _base() -> String:
	return origin_provider.call() if origin_provider.is_valid() else origin


static func _platform_name() -> String:
	match OS.get_name():
		"Android": return "android"
		"iOS": return "ios"
		"macOS": return "macos"
		"Windows": return "windows"
		"Linux", "FreeBSD": return "linux"
	return ""


func _send(method: int, path: String, query := {}, body = null, authenticated := true,
		allow_reauth := true) -> Dictionary:
	if authenticated:
		await ensure_session()

	var url := _base() + path
	if not query.is_empty():
		var parts := []
		for k in query:
			parts.append("%s=%s" % [str(k).uri_encode(), str(query[k]).uri_encode()])
		url += "?" + "&".join(parts)

	var headers := PackedStringArray(["Accept: application/json"])
	if body != null:
		headers.append("Content-Type: application/json")
	var token := identity.session_token if authenticated else ""
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)

	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	var err := http.request(url, headers, method, JSON.stringify(body) if body != null else "")
	if err != OK:
		http.queue_free()
		return _failure(ApiError.new(ApiError.NETWORK, "No connection to the game server."))
	var response: Array = await http.request_completed
	http.queue_free()

	var result: int = response[0]
	var status: int = response[1]
	if result == HTTPRequest.RESULT_TIMEOUT:
		return _failure(ApiError.new(ApiError.TIMEOUT, "The server took too long to answer."))
	if result != HTTPRequest.RESULT_SUCCESS:
		return _failure(ApiError.new(ApiError.NETWORK, "No connection to the game server."))

	var decoded := _decode((response[3] as PackedByteArray).get_string_from_utf8())
	if status >= 200 and status < 300:
		server_reachable.emit()
		return {"ok": true, "data": decoded, "error": null}

	# A token that expired between two screens should cost a round trip, not a
	# trip through the sign-in flow — the device id can always mint a new one.
	if status == 401 and authenticated and allow_reauth:
		identity.clear_session()
		return await _send(method, path, query, body, authenticated, false)

	return _failure(ApiError.from_body(status, decoded))


static func _failure(error: ApiError) -> Dictionary:
	return {"ok": false, "data": {}, "error": error}


## Tolerates an empty body, a truncated one, or a proxy's HTML error page —
## treated as an empty envelope so the status code still decides the outcome.
static func _decode(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var parsed = Wire.parse_json(text)
	return parsed if parsed is Dictionary else {}
