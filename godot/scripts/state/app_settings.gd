extends Node

## App-wide preferences (autoloaded as `Settings`). Display and gameplay
## choices persist in `user://settings.cfg`; anything that identifies the
## *player* is delegated to [member identity], which has its own file — a theme
## is cheap to pick again after a reinstall, an account is not.

signal changed

## The game server every build connects to. The server lives in `backend/`;
## run it locally with `make up` and the socket is served at
## ws://localhost:8080/ws.
const DEFAULT_SERVER_URL := "ws://192.168.1.133:8080/ws"

const PATH := "user://settings.cfg"

const ANIMATION_SCALE := {"slow": 1.6, "normal": 1.0, "fast": 0.6}

var identity: IdentityStore

var _cfg := ConfigFile.new()
var _persistent := true

var theme := "emerald":
	set(v): theme = v; _changed("theme", v)
## Card-face colour style. See [constant Tokens.CARD_FACES].
var card_style := "classic":
	set(v): card_style = v; _changed("card_style", v)
var player_name := "You":
	set(v):
		var t := v.strip_edges()
		if t.is_empty():
			return
		player_name = t
		_changed("player_name", t)
## easy / normal / hard.
var difficulty := "normal":
	set(v): difficulty = v; _changed("difficulty", v)
## Debug-only override for the server URL. Empty means "no override".
var server_url := "":
	set(v): server_url = v.strip_edges(); _changed("server_url", server_url)
## Whether a legal card can be played by dragging it toward the table, as well
## as by tapping it.
var drag_to_play := true:
	set(v): drag_to_play = v; _changed("drag_to_play", v)
## Throw the player's last card automatically — with one card left every play
## is legal, so no choice is skipped.
var auto_throw_last_card := true:
	set(v): auto_throw_last_card = v; _changed("auto_throw_last_card", v)
## Throw the sole remaining card of the led suit automatically — following is
## forced. Leading is never auto-played.
var auto_throw_last_suit_card := true:
	set(v): auto_throw_last_suit_card = v; _changed("auto_throw_last_suit_card", v)
var music_enabled := true:
	set(v): music_enabled = v; _changed("music_enabled", v)
var sfx_enabled := true:
	set(v): sfx_enabled = v; _changed("sfx_enabled", v)
## Whether the table answers touches with a short vibration — a tick as the
## finger slides from card to card, a thump when one is thrown. Defaults on; it
## is the cheapest way to make a card feel picked up.
var haptics_enabled := true:
	set(v): haptics_enabled = v; _changed("haptics_enabled", v)
## Whether a tap only raises a card, and a second tap on the raised card plays
## it. Off by default, so one tap plays as it always has; players who keep
## misfiring on a crowded fan can opt into the safety catch. Dragging a card
## toward the table always plays it straight away either way.
var tap_twice_to_play := false:
	set(v): tap_twice_to_play = v; _changed("tap_twice_to_play", v)
## slow / normal / fast — scales every transient animation and the table's own
## pacing timers.
var animation_speed := "normal":
	set(v): animation_speed = v; _changed("animation_speed", v)
## Arms the debug "Go offline" tooling. Debug builds only.
var debug_mode := false:
	set(v): debug_mode = v; _changed("debug_mode", v)

var _loading := false


func _ready() -> void:
	if identity == null:
		identity = IdentityStore.new(_persistent)
	_load()


## Swaps in throwaway storage — tests call this before touching anything.
func use_memory_storage() -> void:
	_persistent = false
	identity = IdentityStore.new(false)


func animation_scale() -> float:
	return ANIMATION_SCALE.get(animation_speed, 1.0)


## The server the app should actually connect to: the debug override when
## running a debug build with one set, otherwise [constant DEFAULT_SERVER_URL].
func effective_server_url() -> String:
	if OS.is_debug_build() and not server_url.strip_edges().is_empty():
		return server_url
	return DEFAULT_SERVER_URL


func palette() -> Dictionary:
	return Tokens.palette(theme)


func card_face() -> Dictionary:
	return Tokens.card_face(card_style)


func _changed(key: String, value) -> void:
	if _loading:
		return
	_cfg.set_value("settings", key, value)
	if _persistent:
		_cfg.save(PATH)
	changed.emit()


func _load() -> void:
	if not _persistent or _cfg.load(PATH) != OK:
		return
	_loading = true
	for key in _cfg.get_section_keys("settings"):
		if key in self:
			set(key, _cfg.get_value("settings", key))
	_loading = false
