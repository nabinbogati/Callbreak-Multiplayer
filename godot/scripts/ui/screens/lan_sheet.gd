class_name LanSheet
extends MarginContainer

## Fully self-hosted LAN play: host a table for phones on the same Wi‑Fi to
## find, or browse the tables broadcasting nearby and join one with its code.

signal finished(result)

var _code := JoinSheet.new_code()
var _host_tab := true
var _discovery: LanDiscovery
var _body: VBoxContainer
var _list: VBoxContainer
## Typed codes per advert key, so a list refresh keeps what was typed.
var _typed := {}


func _init() -> void:
	add_theme_constant_override("margin_left", int(UI.sc(22, 18)))
	add_theme_constant_override("margin_right", int(UI.sc(22, 18)))
	add_theme_constant_override("margin_top", int(UI.sc(22, 14)))
	add_theme_constant_override("margin_bottom", int(UI.sc(22, 14) + UI.safe.w))
	_body = UI.vbox(0)
	add_child(_body)


func _ready() -> void:
	_discovery = LanDiscovery.new()
	add_child(_discovery)
	_discovery.games_changed.connect(func():
		if not _host_tab:
			_fill_list())
	_build()


func _build() -> void:
	UI.free_children(_body)
	_body.add_child(UI.label("LAN Play", UI.sc(18, 14), Tokens.TEXT_PRIMARY, "bold"))
	_body.add_child(UI.gap(UI.sc(14, 10)))
	_body.add_child(UI.hbox(8, [
		UI.expand(_tab("Host", _host_tab, func(): _switch(true))),
		UI.expand(_tab("Join", not _host_tab, func(): _switch(false))),
	]))
	_body.add_child(UI.gap(UI.sc(18, 12)))
	if _host_tab:
		_body.add_child(UI.label("Game code", UI.sc(13, 11), Tokens.TEXT_MUTED, "semibold", HORIZONTAL_ALIGNMENT_CENTER))
		_body.add_child(UI.gap(UI.sc(8, 5)))
		var code := UI.panel(UI.flat(Tokens.PANEL_SOFT, UI.sc(14, 11), Color(Tokens.GOLD_BORDER, 0.4), 1,
				UI.pad_hv(28, UI.sc(14, 8))), UI.gold_text(_code, UI.sc(34, 26), "bold"))
		code.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_body.add_child(code)
		_body.add_child(UI.gap(UI.sc(22, 14)))
		_body.add_child(UI.button("Host game", true, _host, UI.sc(15, 13), UI.pad_hv(0, UI.sc(15, 11))))
	else:
		_body.add_child(UI.label("Games on your Wi‑Fi", UI.sc(13, 11), Tokens.TEXT_MUTED, "semibold"))
		_body.add_child(UI.gap(UI.sc(8, 5)))
		_list = UI.vbox(8)
		var scroller := UI.scroll(_list)
		scroller.custom_minimum_size.y = UI.sc(220, 150)
		_body.add_child(scroller)
		_fill_list()


func _tab(text: String, selected: bool, on_tap: Callable) -> Control:
	var style := UI.flat(Color(Tokens.GOLD, 0.16) if selected else Tokens.PANEL, UI.sc(12, 9),
			Tokens.GOLD_BORDER if selected else Tokens.HAIRLINE, 1, UI.pad_hv(0, UI.sc(11, 8)))
	return UI.pressable(UI.panel(style, UI.label(text, UI.sc(14, 12), Tokens.GOLD if selected else Tokens.TEXT_ON_DARK,
			"bold", HORIZONTAL_ALIGNMENT_CENTER)), on_tap)


func _switch(host: bool) -> void:
	_host_tab = host
	_build()


func _fill_list() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	UI.free_children(_list)
	var games := _discovery.games()
	if games.is_empty():
		_list.add_child(UI.margin(UI.vbox(10, [
			UI.center(PulseRipple.new(54, "signal")),
			UI.label("Searching for games on your Wi‑Fi…", 12, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER),
		]), Vector4(0, 18, 0, 18)))
		return
	for advert in games:
		_list.add_child(_game_row(advert))


func _game_row(advert: Dictionary) -> Control:
	var key := "%s:%s" % [advert["address"], advert["roomCode"]]
	var code := UI.line_edit(_typed.get(key, ""), "ABCD", 14)
	code.add_theme_font_override("font", Tokens.font("bold"))
	code.custom_minimum_size = Vector2(84, 40)
	code.max_length = 8
	var error := UI.label("", 11, Tokens.DANGER)
	error.visible = false
	code.text_changed.connect(func(t):
		var caret := code.caret_column
		code.text = t.to_upper()
		code.caret_column = caret
		_typed[key] = code.text
		error.visible = false)
	var submit := func():
		var typed := code.text.strip_edges().to_upper()
		if typed.is_empty():
			error.text = "Enter the game code"
			error.visible = true
		elif typed != str(advert["roomCode"]).to_upper():
			error.text = "That code does not match this game."
			error.visible = true
		else:
			_join(advert)
	code.text_submitted.connect(func(_t): submit.call())
	var info := UI.vbox(2, [
		UI.label(advert["hostName"], 14, Tokens.TEXT_PRIMARY, "bold"),
		UI.label("%d/%d players" % [advert["playerCount"], advert["maxPlayers"]], 11, Tokens.TEXT_MUTED),
	])
	var join := UI.button("Join", true, submit, 13, UI.pad_hv(16, 10))
	join.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := UI.hbox(10, [UI.expand(info), code, join])
	return UI.panel(UI.flat(Tokens.PANEL, 12, Tokens.HAIRLINE, 1, UI.pad_hv(14, 10)), UI.vbox(6, [row, error]))


func _host() -> void:
	var session := LanHostSession.new(Settings.player_name, _code, Settings.difficulty, 3, Settings.animation_scale())
	finished.emit(null)
	var table := TableScreen.new(session)
	App.instance.push(table)
	session.start_hosting()


func _join(advert: Dictionary) -> void:
	var session := Sessions.remote(advert["wsUrl"], advert["roomCode"], "lan")
	finished.emit(null)
	App.instance.push(TableScreen.new(session))
