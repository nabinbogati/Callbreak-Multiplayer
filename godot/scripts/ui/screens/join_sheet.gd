class_name JoinSheet
extends MarginContainer

## Where to connect and which table to sit at, per mode. Finishes with
## `{serverUrl, roomCode, handsPerGame, creating}` — or null if dismissed.
##
## vs Bots and Online ask only for a match length (Online connects to the
## matchmaking server). Private creates a room under a fresh code or joins one
## a friend shared; the creator's table opens on Quickplay and the host can
## change it in the lobby.

signal finished(result)

const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var mode: String
var _creating := true
var _hands := 3
var _room: LineEdit
var _error := ""
var _body: VBoxContainer


func _init(mode_in: String) -> void:
	mode = mode_in
	add_theme_constant_override("margin_left", int(UI.sc(22, 18)))
	add_theme_constant_override("margin_right", int(UI.sc(22, 18)))
	add_theme_constant_override("margin_top", int(UI.sc(22, 14)))
	add_theme_constant_override("margin_bottom", int(UI.sc(22, 14) + UI.safe.w))
	_room = UI.line_edit(new_code() if mode == "private" else "", "ABCD", UI.sc(16, 13))
	_room.add_theme_font_override("font", Tokens.font("bold"))
	_room.max_length = 8
	_room.text_changed.connect(func(_t):
		var caret := _room.caret_column
		_room.text = _room.text.to_upper()
		_room.caret_column = caret
		if not _error.is_empty():
			_error = ""
			_build())
	_room.text_submitted.connect(func(_t): _submit())
	_body = UI.vbox(0)
	add_child(UI.scroll(_body) if not UI.portrait else _body)
	_build()


static func new_code() -> String:
	var out := ""
	for i in 4:
		out += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
	return out


func _hint() -> String:
	match mode:
		"private":
			return "Share the room code with your friends. Empty seats are filled with bots when the host starts." \
					if _creating else "Enter the room code a friend shared with you."
		"online":
			return "Connects to the matchmaking server. Pick how long you want to play."
	return "Pick how long you want to play."


func _build() -> void:
	if _room.get_parent() != null:
		_room.get_parent().remove_child(_room)
	UI.free_children(_body)
	_body.add_child(UI.label(GameSession.mode_label(mode), UI.sc(18, 14), Tokens.TEXT_PRIMARY, "bold"))
	_body.add_child(UI.gap(UI.sc(6, 4)))
	_body.add_child(UI.paragraph(_hint(), UI.sc(12, 11), Tokens.TEXT_MUTED))
	_body.add_child(UI.gap(UI.sc(18, 10)))

	if mode == "private":
		var tabs := UI.hbox(8, [
			UI.expand(_tab("Create", _creating, func(): _set_creating(true))),
			UI.expand(_tab("Join", not _creating, func(): _set_creating(false))),
		])
		_body.add_child(tabs)
		_body.add_child(UI.gap(UI.sc(18, 10)))
		_body.add_child(_field_label("Room code"))
		_body.add_child(UI.gap(UI.sc(8, 5)))
		_room.placeholder_text = "Your room code" if _creating else "ABCD"
		_body.add_child(_room)
	else:
		_body.add_child(_field_label("Match length"))
		_body.add_child(UI.gap(UI.sc(8, 5)))
		_body.add_child(UI.hbox(UI.sc(10, 8), [
			UI.expand(RoundsCard.make("Quickplay", "3 hands · fast matches", _hands == 3, func(): _set_hands(3))),
			UI.expand(RoundsCard.make("Normal Play", "5 hands · the full game", _hands == 5, func(): _set_hands(5))),
		]))

	if not _error.is_empty():
		_body.add_child(UI.gap(UI.sc(12, 8)))
		_body.add_child(UI.panel(UI.flat(Color(Tokens.DANGER, 0.1), 10, Color(Tokens.DANGER, 0.4), 1, UI.pad_hv(12, 8)),
				UI.paragraph(_error, UI.sc(11.5, 10.5), Tokens.DANGER)))
	_body.add_child(UI.gap(UI.sc(22, 12)))
	var label := "Connect"
	match mode:
		"private": label = "Create room" if _creating else "Join room"
		"bots": label = "Start game"
		"online": label = "Find match"
	_body.add_child(UI.button(label, true, _submit, UI.sc(15, 13), UI.pad_hv(0, UI.sc(15, 11))))


func _field_label(text: String) -> Label:
	return UI.label(text, UI.sc(12, 11), Tokens.TEXT_MUTED, "semibold")


func _tab(text: String, selected: bool, on_tap: Callable) -> Control:
	var style := UI.flat(Color(Tokens.GOLD, 0.16) if selected else Tokens.PANEL, UI.sc(12, 9),
			Tokens.GOLD_BORDER if selected else Tokens.HAIRLINE, 1, UI.pad_hv(0, UI.sc(11, 8)))
	return UI.pressable(UI.panel(style, UI.label(text, UI.sc(14, 12), Tokens.GOLD if selected else Tokens.TEXT_ON_DARK,
			"bold", HORIZONTAL_ALIGNMENT_CENTER)), on_tap)


func _set_creating(on: bool) -> void:
	_creating = on
	_room.text = new_code() if on else ""
	_error = ""
	_build()


func _set_hands(h: int) -> void:
	_hands = h
	_build()


func _submit() -> void:
	match mode:
		"bots":
			finished.emit({"handsPerGame": _hands})
		"online":
			finished.emit({"serverUrl": Settings.effective_server_url(), "roomCode": RemoteSession.QUICKPLAY_ROOM,
					"handsPerGame": _hands})
		"private":
			var room := _room.text.strip_edges().to_upper()
			if room.is_empty():
				_error = "Pick a room code and share it with your friends." if _creating \
						else "Type the room code your friend shared."
				_build()
				return
			# Only the creating side sends a length: joining plays whatever the
			# room was created with, and the host can still change it.
			finished.emit({"serverUrl": Settings.effective_server_url(), "roomCode": room, "creating": _creating,
					"handsPerGame": _hands if _creating else 0})
