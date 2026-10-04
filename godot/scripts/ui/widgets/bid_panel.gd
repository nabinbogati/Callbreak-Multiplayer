class_name BidPanel
extends PanelContainer

## The bidding sheet: how many tricks you'll take this hand, 1–13.
##
## Every possible bid is on screen at once, so choosing is a single tap rather
## than a walk up and down a stepper. The suggested bid starts selected and
## keeps a star so the player can always find their way back to it. Shows a
## draining bar when the table will bid for the player if they wait too long.

signal bid_chosen(bid: int)

const PER_ROW := 7

var _value := 1
var _suggested := 1
var _big: BigValue
var _rows: VBoxContainer
var _chips: Array[BidChip] = []
var _suggest_label: Label
var _suggest_icon: IconView
var _suggest_style: StyleBoxFlat
var deadline_bar: DeadlineBar


## [param max_height] is the most of the screen the panel may take; past it the
## content scrolls.
func _init(hand: Array, deadline_ms := 0, max_height := INF) -> void:
	_suggested = Rules.suggest_bid(hand)
	_value = _suggested
	var pad := Vector4(18, UI.sc(16, 12), 18, UI.sc(18, 12))
	add_theme_stylebox_override("panel", UI.glass_box(pad))
	var col := UI.vbox(0)

	var titles := UI.vbox(0, [UI.label("Your bid", UI.sc(17, 15), Tokens.TEXT_PRIMARY, "bold"),
			UI.label("How many tricks will you take?", UI.sc(11.5, 10.5), Tokens.TEXT_MUTED, "medium")])
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.alignment = BoxContainer.ALIGNMENT_CENTER
	_big = BigValue.new(UI.sc(38, 30), _value)
	col.add_child(UI.hbox(0, [titles, _big]))
	col.add_child(UI.gap(UI.sc(14, 8)))

	_rows = UI.vbox(UI.sc(6, 5))
	var row: HBoxContainer
	for bid in range(Rules.MIN_BID, Rules.MAX_BID + 1):
		if (bid - Rules.MIN_BID) % PER_ROW == 0:
			row = UI.hbox(UI.sc(6, 5))
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			_rows.add_child(row)
		var chip := BidChip.new(bid, bid == _suggested)
		_chips.append(chip)
		row.add_child(UI.pressable(chip, Callable(), 0.88))
		(row.get_child(row.get_child_count() - 1) as Pressable).pressed.connect(_select.bind(bid))
	_rows.resized.connect(_size_chips)
	col.add_child(_rows)
	col.add_child(UI.gap(UI.sc(10, 6)))

	# The engine's estimate, and a way back to it.
	_suggest_style = UI.flat(Tokens.PANEL, 12, Tokens.HAIRLINE, 1, UI.pad_hv(12, UI.sc(6, 4)))
	_suggest_icon = UI.icon("auto_awesome_rounded", 13, Tokens.GOLD)
	_suggest_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_suggest_label = UI.label("", UI.sc(12, 11), Tokens.GOLD, "medium")
	var chip := UI.pressable(UI.panel(_suggest_style, UI.hbox(6, [_suggest_icon, _suggest_label])),
			func(): _select(_suggested), 0.96)
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(chip)
	col.add_child(UI.gap(UI.sc(14, 8)))

	col.add_child(UI.gold_button("Confirm bid", func(): bid_chosen.emit(_value), "", not UI.portrait))

	deadline_bar = DeadlineBar.new("Bidding for you", deadline_ms)
	var bar_wrap := UI.vbox(0, [UI.gap(UI.sc(12, 8)), deadline_bar])
	bar_wrap.visible = deadline_ms > 0
	col.add_child(bar_wrap)
	# Scrollable defensively: a short screen, a phone on its side most of all,
	# leaves little height.
	add_child(UI.fit_scroll(col, max_height - pad.y - pad.w))
	_refresh()


## Seven to a row across the panel's width, square in portrait and a little
## squat in landscape.
func _size_chips() -> void:
	var gap := UI.sc(6, 5)
	var size_px := floorf((_rows.size.x - gap * (PER_ROW - 1)) / PER_ROW)
	if size_px <= 0:
		return
	for c in _chips:
		var h := size_px if UI.portrait else size_px * 0.82
		if c.custom_minimum_size != Vector2(size_px, h):
			c.custom_minimum_size = Vector2(size_px, h)


func _select(v: int) -> void:
	if v == _value:
		return
	Haptics.tick()
	_value = v
	_refresh()


func _refresh() -> void:
	_big.value = _value
	for c in _chips:
		c.selected = c.value == _value
	var at_suggestion := _value == _suggested
	_suggest_label.text = "Suggested: %d" % _suggested if at_suggestion else "Suggested: %d · tap to use" % _suggested
	_suggest_label.add_theme_color_override("font_color", Tokens.GOLD if at_suggestion else Tokens.TEXT_MUTED)
	_suggest_style.border_color = Color(Tokens.GOLD_BORDER, 0.5) if at_suggestion else Tokens.HAIRLINE


## The chosen number, large, rolling to each new value.
class BigValue:
	extends Control

	var value := 0:
		set(v):
			if v == value or _new == null:
				value = v
				return
			_old.text = _new.text
			value = v
			_new.text = str(v)
			_t = 0.0
			set_process(true)
			_place()
	var _new: Label
	var _old: Label
	var _t := 1.0

	func _init(size_in: float, initial: int) -> void:
		value = initial
		custom_minimum_size = Vector2(size_in * 1.5, size_in * 1.25)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_old = UI.gold_text("", size_in)
		_new = UI.gold_text(str(initial), size_in)
		for l in [_old, _new]:
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			add_child(l)
		resized.connect(_place)
		set_process(false)

	func _place() -> void:
		for l in [_old, _new]:
			l.position = Vector2.ZERO
			l.size = size
			l.pivot_offset = size / 2.0
		_old.visible = _t < 1.0
		_new.modulate.a = Motion.enter(_t)
		_new.scale = Vector2.ONE * (0.6 + 0.4 * Motion.enter(_t))
		_old.modulate.a = 1.0 - _t

	func _process(delta: float) -> void:
		_t = minf(_t + delta / 0.22, 1.0)
		if _t >= 1.0:
			set_process(false)
		_place()


class BidChip:
	extends Control

	var value: int
	var suggested: bool
	var selected := false:
		set(v):
			if v != selected:
				selected = v
				queue_redraw()

	func _init(value_in: int, suggested_in: bool) -> void:
		value = value_in
		suggested = suggested_in
		custom_minimum_size = Vector2(36, 36)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		var w := size.x
		if selected:
			Draw.box_shadow(self, rect, 10, Tokens.glow(Tokens.GOLD_DEEP, 0.9, 12))
			Draw.rounded_rect(self, rect, 10, Tokens.GOLD_BUTTON, true, Color("#FFF6D899"), 1.0, Tokens.GOLD_BUTTON_STOPS)
		else:
			Draw.fill(self, Draw.rounded_rect_points(rect, 10), Color("#FFFFFF14"))
			Draw.stroke_rounded_rect(self, rect, 10,
					Color(Tokens.GOLD_BORDER, 0.7) if suggested else Tokens.HAIRLINE_STRONG, 1.4 if suggested else 1.0)
		SeatView.centered_text(self, str(value), size / 2.0, w * 0.4, "bold",
				Tokens.ON_GOLD if selected else Tokens.TEXT_PRIMARY)
		if suggested:
			var star := w * 0.26
			Draw.icon(self, "star_rounded", Rect2(w - w * 0.08 - star, w * 0.06, star, star),
					Tokens.ON_GOLD if selected else Tokens.GOLD)
