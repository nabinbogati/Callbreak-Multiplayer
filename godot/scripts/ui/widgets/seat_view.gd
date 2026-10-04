class_name SeatView
extends BoxContainer

## One player's place at the table: name chip, avatar and bid chip — in a row
## at the top and bottom, a column at the sides. Opponents' avatars wear their
## face-down hand as a small fan pointing at the table centre.

enum Slot { BOTTOM, LEFT, TOP, RIGHT }

var slot: int
var avatar: SeatAvatar
var _name_label: Label
var _host_mark: Control
var _dealer_mark: Control
var _bid_label: Label
var _tricks_label: Label


## Where [param seat] sits on screen for [param viewer]: always bottom for the
## viewer, then clockwise.
static func slot_for(seat: int, viewer: int) -> int:
	return (seat - maxi(viewer, 0) + 4) % 4


func _init(slot_in: int) -> void:
	slot = slot_in
	vertical = slot == Slot.LEFT or slot == Slot.RIGHT
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", int(UI.sc(6, 4)))
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var is_you := slot == Slot.BOTTOM
	var name_row := UI.hbox(UI.sc(4, 3))
	_host_mark = _mark("crown")
	_name_label = UI.label("", UI.sc(11, 9), Tokens.TEXT_PRIMARY, "semibold")
	_name_label.clip_text = true
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.custom_minimum_size.x = 0
	_dealer_mark = _mark("D")
	name_row.add_child(_host_mark)
	name_row.add_child(_name_label)
	name_row.add_child(_dealer_mark)
	var name_chip := UI.panel(_chip_style(UI.pad_hv(UI.sc(8, 6), UI.sc(4, 3))), name_row)
	name_chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	name_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	avatar = SeatAvatar.new(UI.sc(46, 45) if is_you else UI.sc(38, 39), slot)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	_bid_label = UI.label("–", UI.sc(12, 10), Tokens.GOLD, "bold")
	var slash := UI.label("/", UI.sc(11, 9), Color(Tokens.TEXT_PRIMARY, 0.35), "semibold")
	_tricks_label = UI.label("0", UI.sc(12, 10), Tokens.TEXT_ON_DARK, "bold")
	var bid_chip := UI.panel(_chip_style(UI.pad_hv(UI.sc(7, 5), UI.sc(4, 3))),
			UI.hbox(UI.sc(3, 2), [_bid_label, slash, _tricks_label]))
	bid_chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	bid_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	add_child(name_chip)
	add_child(avatar)
	add_child(bid_chip)
	for c in [name_chip, bid_chip]:
		_ignore(c)


func _ignore(node: Node) -> void:
	if node is Control:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in node.get_children():
		_ignore(c)


static func _chip_style(pad: Vector4) -> StyleBox:
	return UI.with_shadow(UI.flat(Tokens.CHIP, UI.sc(11, 8), Tokens.HAIRLINE, 1, pad),
			Color(0, 0, 0, 0.45), 12, Vector2(0, 4))


func _mark(kind: String) -> Control:
	var s := UI.sc(13, 10)
	var box := UI.panel(UI.flat(Color(Tokens.GOLD, 0.18), UI.sc(4, 3)))
	box.custom_minimum_size = Vector2(s, s)
	if kind == "D":
		var l := UI.label("D", UI.sc(8, 7), Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		box.add_child(l)
	else:
		box.add_child(UI.center(UI.icon("crown", UI.sc(9, 7), Tokens.GOLD)))
	box.visible = false
	return box


## Refreshes everything from the current view.
func update(player: Dictionary, bid: int, tricks: int, is_turn: bool, is_dealer: bool, is_host: bool,
		deadline_ms: int, hand_count: int) -> void:
	_name_label.text = str(player.get("name", ""))
	_name_label.custom_minimum_size.x = 0
	var max_w := UI.sc(84, 62)
	var w := Tokens.font("semibold").get_string_size(_name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(UI.sc(11, 9))).x
	_name_label.custom_minimum_size.x = minf(w + 1, max_w)
	_name_label.size_flags_horizontal = Control.SIZE_FILL
	_host_mark.visible = is_host
	_dealer_mark.visible = is_dealer
	_bid_label.text = "–" if bid < 0 else str(bid)
	_tricks_label.text = str(tricks)
	_tricks_label.add_theme_color_override("font_color",
			Tokens.SUCCESS if bid >= 0 and tricks >= bid else Tokens.TEXT_ON_DARK)
	avatar.update(player, is_turn, deadline_ms, hand_count if slot != Slot.BOTTOM else 0)


## The avatar's centre in this seat's parent's coordinates.
func avatar_center_in(node: Control) -> Vector2:
	return avatar.get_global_rect().get_center() - node.get_global_rect().position


class SeatAvatar:
	extends Control

	var diameter: float
	var slot: int
	var player := {}
	var is_turn := false
	var hand_count := 0
	var clock: TurnClock
	var _turn_alpha := 0.0
	var _tween: Tween

	func _init(d: float, slot_in: int) -> void:
		diameter = d
		slot = slot_in
		var ring := d + 8.0
		custom_minimum_size = Vector2(ring, ring)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clock = TurnClock.new()
		clock.audible = slot == SeatView.Slot.BOTTOM
		clock.size = Vector2(ring, ring)
		clock.custom_minimum_size = Vector2(ring, ring)
		add_child(clock)
		Settings.changed.connect(queue_redraw)

	func update(p: Dictionary, turn: bool, deadline_ms: int, count: int) -> void:
		player = p
		hand_count = count
		clock.deadline_ms = deadline_ms
		if turn != is_turn:
			is_turn = turn
			if _tween != null:
				_tween.kill()
			_tween = create_tween()
			_tween.tween_method(_set_turn_alpha, _turn_alpha, 1.0 if turn else 0.0, 0.22)
		queue_redraw()

	func _set_turn_alpha(v: float) -> void:
		_turn_alpha = v
		queue_redraw()

	func _draw() -> void:
		var ring := diameter + 8.0
		var c := Vector2(ring, ring) / 2.0
		var is_you := slot == SeatView.Slot.BOTTOM
		_draw_hand_fan(c, ring)
		if _turn_alpha > 0.01:
			for i in 3:
				draw_circle(c, ring / 2.0 + 2.0 + i * 3.0, Color(Tokens.GOLD, 0.12 * _turn_alpha * (1.0 - i / 3.0)),
						true, -1.0, true)
			draw_arc(c, ring / 2.0 - 1.0, 0, TAU, 48, Color(Tokens.GOLD, 0.9 * _turn_alpha), 2.0, true)
		var rect := Rect2(c - Vector2(diameter, diameter) / 2.0, Vector2(diameter, diameter))
		Draw.shadow(self, rect, diameter / 2.0, Vector2(0, 3), 10, Color(0, 0, 0, 0.45))
		var stops: Array = [Tokens.GOLD, Tokens.GOLD_DEEP] if is_you else Settings.palette()["avatar"]
		Draw.rounded_rect(self, rect, diameter / 2.0, stops, true,
				Color(Tokens.GOLD_LIGHT, 0.9) if is_you else Color(Tokens.TEXT_MUTED, 0.3), 2.0 if is_you else 1.5)
		var font := Tokens.font("bold")
		var fs := int(diameter * 0.37)
		var initial := GameView.initial(str(player.get("name", "")))
		var tw := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, c + Vector2(-tw / 2.0, fs * 0.36), initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Tokens.ON_GOLD if is_you else Tokens.TEXT_ON_DARK)
		var connected: bool = player.get("connected", true)
		var bot := GameView.is_bot(player)
		if not connected:
			draw_circle(c, diameter / 2.0, Color(0, 0, 0, 0.7), true, -1.0, true)
			Draw.icon(self, "wifi_off", Rect2(c - Vector2.ONE * diameter * 0.19, Vector2.ONE * diameter * 0.38),
					Tokens.TEXT_MUTED)
		var badge := diameter * 0.34
		if bot or not connected:
			_bot_badge(rect.position + Vector2(badge / 2.0, badge / 2.0) - Vector2(2, 2), badge)
		if player.get("autoplay", false) and connected:
			_bot_badge(Vector2(rect.end.x - badge / 2.0 + 2, rect.position.y + badge / 2.0 - 2), badge)
		if not bot:
			var dot := diameter * 0.28
			var dc := rect.end - Vector2(dot / 2.0, dot / 2.0) + Vector2(1, 1)
			if connected:
				draw_circle(dc, dot * 0.8, Color(Tokens.SUCCESS, 0.25), true, -1.0, true)
			draw_circle(dc, dot / 2.0, Color(0.039, 0.071, 0.027, 0.9), true, -1.0, true)
			draw_circle(dc, dot / 2.0 - dot * 0.18, Tokens.SUCCESS if connected else Tokens.TEXT_MUTED, true, -1.0, true)

	func _bot_badge(center: Vector2, size: float) -> void:
		draw_circle(center, size / 2.0, Color(0.039, 0.071, 0.027, 0.9), true, -1.0, true)
		draw_arc(center, size / 2.0 - size * 0.045, 0, TAU, 24, Tokens.GOLD_MID, size * 0.09, true)
		Draw.icon(self, "robot", Rect2(center - Vector2.ONE * size * 0.29, Vector2.ONE * size * 0.58), Tokens.GOLD_MID)

	## A face-down fan of the opponent's remaining cards, tucked behind the
	## avatar and opening toward the table centre.
	func _draw_hand_fan(c: Vector2, _ring: float) -> void:
		if hand_count <= 0 or slot == SeatView.Slot.BOTTOM:
			return
		var cw := UI.sc(26, 22)
		var ch := cw * CardView.BACK_ASPECT
		var sweep := (hand_count - 1) * 0.15
		var dir0: Vector2
		var base: float
		match slot:
			SeatView.Slot.TOP: dir0 = Vector2(0, 1); base = 0.0
			SeatView.Slot.LEFT: dir0 = Vector2(1, 0); base = -PI / 2
			_: dir0 = Vector2(-1, 0); base = PI / 2
		for i in hand_count:
			var t := 0.0 if hand_count == 1 else float(i) / (hand_count - 1) - 0.5
			var theta := t * sweep
			var dir := dir0.rotated(theta)
			var center := c + dir * (ch / 2.0)
			draw_set_transform(center, base + theta, Vector2.ONE)
			CardView.paint_back(self, Rect2(-Vector2(cw, ch) / 2.0, Vector2(cw, ch)), false, i == hand_count - 1)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
