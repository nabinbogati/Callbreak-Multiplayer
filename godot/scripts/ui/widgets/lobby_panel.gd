class_name LobbyPanel
extends CenterContainer

## A table waiting to be dealt: the room code (or "Finding players"), who is
## seated, the match length, the countdown, and Start / Leave.

signal start_pressed
signal leave_pressed
signal hands_changed(hands: int)


func _init(lobby: Dictionary, countdown: int) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var online: bool = lobby.get("isOnline", false)
	var is_host: bool = lobby.get("isHost", false)
	var seats: Array = lobby.get("seats", [])
	var col := UI.vbox(0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER

	if online:
		col.add_child(UI.label("Finding players", 22, Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER))
	else:
		var code := UI.panel(UI.flat(Tokens.PANEL_SOFT, UI.sc(14, 11), Color(Tokens.GOLD_BORDER, 0.4), 1,
				UI.pad_hv(28, UI.sc(18, 10))), UI.gold_text(lobby.get("room", ""), UI.sc(34, 26)))
		code.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(code)
	col.add_child(UI.gap(4))
	col.add_child(UI.paragraph(_subtitle(lobby), 12, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(20))

	var seat_row := UI.hbox(14)
	seat_row.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in 4:
		var occupant := {}
		for s in seats:
			if s["seat"] == i:
				occupant = s
		seat_row.add_child(_seat(occupant, UI.sc(52, 44)))
	col.add_child(seat_row)
	col.add_child(UI.gap(20))

	if not online:
		col.add_child(_hands_picker(int(lobby.get("handsPerGame", 5)), is_host))
		col.add_child(UI.gap(20))

	if countdown > 0:
		col.add_child(UI.label("Starting in %d…" % countdown, 15, Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER))
	elif lobby.get("canStart", false) and is_host:
		var start := UI.button("Start game", true, func(): start_pressed.emit(), 13, UI.pad_hv(28, 12))
		start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(start)
	else:
		var hint := "You can leave any time before the game starts." if online else \
				("Waiting for at least one more player — you need 2 to start." if is_host else "Waiting for the host to start…")
		col.add_child(UI.paragraph(hint, 12, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(14))
	var leave := UI.pressable(UI.panel(UI.flat(Color.TRANSPARENT, 12, Color(Tokens.TEXT_MUTED, 0.4), 1, UI.pad_hv(28, 12)),
			UI.label("Leave", 13, Tokens.TEXT_MUTED, "bold", HORIZONTAL_ALIGNMENT_CENTER)), func(): leave_pressed.emit())
	leave.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(leave)

	col.custom_minimum_size.x = 300
	add_child(UI.margin(col, UI.pad_all(24)))


static func _subtitle(lobby: Dictionary) -> String:
	var seats: Array = lobby.get("seats", [])
	if lobby.get("isOnline", false):
		var need := maxi(0, int(lobby.get("minPlayers", 1)) - int(lobby.get("humansSeated", 0)))
		if need > 0:
			return "Waiting for %d more %s. A game needs at least %d." % [need, "player" if need == 1 else "players",
					int(lobby.get("minPlayers", 1))]
		return "The table is full." if seats.size() >= 4 else "Starting soon. Any empty seats become bots."
	return "The table is full." if seats.size() >= 4 else "Share the code. Empty seats become bots."


func _seat(occupant: Dictionary, size: float) -> Control:
	var col := UI.vbox(6)
	col.custom_minimum_size.x = size + 26
	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(size, size)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var empty := occupant.is_empty()
	avatar.draw.connect(func():
		var c := avatar.size / 2.0
		if empty:
			var t := (sin(Time.get_ticks_msec() / 1400.0 * PI) + 1.0) / 2.0
			avatar.draw_circle(c, size / 2.0, Color(Tokens.TEXT_PRIMARY, 0.04 + 0.03 * t), true, -1.0, true)
			avatar.draw_arc(c, size / 2.0 - 0.75, 0, TAU, 40, Color(Tokens.TEXT_MUTED, 0.25 + 0.25 * t), 1.5, true)
			Draw.icon(avatar, "person_add", Rect2(c - Vector2.ONE * size * 0.2, Vector2.ONE * size * 0.4),
					Color(Tokens.TEXT_MUTED, 0.5 + 0.25 * t))
			return
		var you: bool = occupant["isYou"]
		var alpha := 1.0 if occupant["connected"] else 0.45
		var rect := Rect2(Vector2.ZERO, avatar.size)
		var stops: Array = ([Tokens.GOLD, Tokens.GOLD_DEEP] if you else Settings.palette()["avatar"]).map(
				func(col_): return Color(col_, alpha))
		Draw.rounded_rect(avatar, rect, size / 2.0, stops, true,
				Color(Tokens.GOLD_LIGHT, 0.9 * alpha) if you else Color(Tokens.TEXT_MUTED, 0.3 * alpha), 2.0 if you else 1.5)
		if occupant["isBot"]:
			Draw.icon(avatar, "robot", Rect2(c - Vector2.ONE * size * 0.225, Vector2.ONE * size * 0.45),
					Color(Tokens.TEXT_ON_DARK, alpha))
		else:
			var font := Tokens.font("bold")
			var fs := int(size * 0.37)
			var initial := GameView.initial(occupant["name"])
			var tw := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			avatar.draw_string(font, c + Vector2(-tw / 2.0, fs * 0.36), initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Color(Tokens.ON_GOLD if you else Tokens.TEXT_ON_DARK, alpha)))
	if empty:
		var pulse := Timer.new()
		pulse.wait_time = 1.0 / 30.0
		pulse.autostart = true
		pulse.timeout.connect(avatar.queue_redraw)
		avatar.add_child(pulse)
	col.add_child(avatar)
	var name := UI.label("Open" if empty else occupant["name"], 12,
			Tokens.TEXT_MUTED if empty or not occupant["connected"] else Tokens.TEXT_PRIMARY, "semibold",
			HORIZONTAL_ALIGNMENT_CENTER)
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(name)
	if not empty:
		if occupant["isYou"] and not occupant["isBot"]:
			col.add_child(UI.label("you", 10, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER))
		if occupant["isHost"] and not occupant["isYou"]:
			var badge := UI.panel(UI.flat(Color(Tokens.GOLD, 0.15), 6, Color(Tokens.GOLD_BORDER, 0.6), 1, UI.pad_hv(7, 2)),
					UI.hbox(3, [UI.icon("crown", 10, Tokens.GOLD), UI.label("host", 9, Tokens.GOLD, "bold")]))
			badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			col.add_child(badge)
		if occupant["isBot"]:
			col.add_child(UI.label("bot", 10, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER))
	return col


func _hands_picker(hands: int, editable: bool) -> Control:
	var col := UI.vbox(UI.sc(8, 4), [UI.label("Match length", UI.sc(12, 11), Tokens.TEXT_MUTED, "semibold",
			HORIZONTAL_ALIGNMENT_CENTER)])
	if not editable:
		col.add_child(UI.label("Quickplay · 3 hands" if hands == 3 else "Normal Play · 5 hands", UI.sc(14, 12),
				Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER))
		return col
	var row := UI.hbox(UI.sc(10, 8), [
		UI.expand(RoundsCard.make("Quickplay", "3 hands · fast matches", hands == 3, func(): hands_changed.emit(3), true)),
		UI.expand(RoundsCard.make("Normal Play", "5 hands · the full game", hands == 5, func(): hands_changed.emit(5), true)),
	])
	row.custom_minimum_size.x = 300
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(row)
	return col
