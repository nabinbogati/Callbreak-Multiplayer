class_name BidPanel
extends PanelContainer

## Choosing a bid: a − / + stepper starting at the suggested bid, a chip that
## restores the suggestion, and Confirm. Shows a draining bar when the table
## will bid for the player if they wait too long.

signal bid_chosen(bid: int)

var _value := 1
var _suggested := 1
var _value_label: Label
var _minus: Pressable
var _plus: Pressable
var _suggest_label: Label
var _suggest_style: StyleBoxFlat
var deadline_bar: DeadlineBar


func _init(hand: Array, deadline_ms := 0) -> void:
	_suggested = Rules.suggest_bid(hand)
	_value = _suggested
	add_theme_stylebox_override("panel", UI.with_shadow(UI.flat(Tokens.DIALOG, 18, Color(Tokens.GOLD_BORDER, 0.35), 1,
			Vector4(20, 18, 20, 20)), Color(0, 0, 0, 0.6), 30, Vector2(0, 12)))
	var col := UI.vbox(0)

	_minus = _step_button(false)
	_plus = _step_button(true)
	_value_label = UI.gold_text(str(_value), 34)
	_value_label.custom_minimum_size.x = 48
	var stepper := UI.hbox(0, [_minus, _value_label, _plus])
	stepper.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(stepper)
	col.add_child(UI.gap(12))

	_suggest_style = UI.flat(Tokens.PANEL, 12, Tokens.HAIRLINE, 1, UI.pad_hv(14, 7))
	_suggest_label = UI.label("", 12, Tokens.GOLD, "medium", HORIZONTAL_ALIGNMENT_CENTER)
	var chip := UI.pressable(UI.panel(_suggest_style, _suggest_label), func(): _set_value(_suggested), 0.96)
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(chip)
	col.add_child(UI.gap(18))

	var confirm := UI.button("Confirm bid", true, func(): bid_chosen.emit(_value), 14, Vector4(0, 14, 0, 14))
	col.add_child(confirm)

	deadline_bar = DeadlineBar.new("Bidding for you", deadline_ms)
	var bar_wrap := UI.vbox(0, [UI.gap(12), deadline_bar])
	bar_wrap.visible = deadline_ms > 0
	col.add_child(bar_wrap)
	add_child(col)
	_refresh()


func _step_button(plus: bool) -> Pressable:
	var face := Control.new()
	face.custom_minimum_size = Vector2(44, 44)
	var p := UI.pressable(face, func(): _set_value(_value + (1 if plus else -1)), 0.86)
	face.draw.connect(func():
		var enabled := (_value < Rules.MAX_BID) if plus else (_value > Rules.MIN_BID)
		var c := Vector2(22, 22)
		face.draw_circle(c, 22, Tokens.PANEL, true, -1.0, true)
		face.draw_arc(c, 21.5, 0, TAU, 40, Color(Tokens.GOLD_BORDER, 0.6) if enabled else Tokens.HAIRLINE, 1.0, true)
		var col := Tokens.GOLD if enabled else Tokens.TEXT_FAINT
		face.draw_line(c - Vector2(8.5, 0), c + Vector2(8.5, 0), col, 2.5, true)
		if plus:
			face.draw_line(c - Vector2(0, 8.5), c + Vector2(0, 8.5), col, 2.5, true))
	return p


func _set_value(v: int) -> void:
	_value = Rules.clamp_bid(v)
	_refresh()


func _refresh() -> void:
	_value_label.text = str(_value)
	var at_suggestion := _value == _suggested
	_suggest_label.text = "Suggested: %d" % _suggested if at_suggestion else "Suggested: %d · tap to use" % _suggested
	_suggest_label.add_theme_color_override("font_color", Tokens.GOLD if at_suggestion else Tokens.TEXT_MUTED)
	_suggest_style.border_color = Color(Tokens.GOLD_BORDER, 0.5) if at_suggestion else Tokens.HAIRLINE
	for b in [_minus, _plus]:
		b.get_child(0).queue_redraw()
