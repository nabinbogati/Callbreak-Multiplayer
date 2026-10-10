class_name DeadlineBar
extends VBoxContainer

## A draining bar and caption for a deadline the player is about to be carried
## past — the bid they have not confirmed, the scoreboard nobody dismissed.
## Unlike [TurnClock] it shows for the whole wait: what it says (*this gets
## decided with or without you*) is worth knowing before the last second. It
## only reports; the host acts on the deadline.

const ALARM_SECONDS := 5

## What happens at zero, e.g. "Bidding for you".
var caption := ""
var deadline_ms := 0:
	set(v):
		deadline_ms = v
		_span = 0
		_shown_seconds = -1
		visible = v > 0
		set_process(v > 0)

var _span := 0
var _bar: Control
var _label: Label
var _shown_seconds := -1


func _init(caption_in := "", deadline := 0) -> void:
	caption = caption_in
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar = Control.new()
	_bar.custom_minimum_size.y = 4
	_bar.draw.connect(_draw_bar)
	add_child(_bar)
	_label = UI.label("", 11, Tokens.GOLD_MID, "medium", HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_label)
	deadline_ms = deadline


func _ready() -> void:
	# Godot switches processing on here for any script with a _process; with no
	# deadline there is nothing to count down, and nothing to redraw.
	set_process(deadline_ms > 0)


func _process(_delta: float) -> void:
	var left := maxi(0, deadline_ms - Time.get_ticks_msec())
	if _span == 0:
		_span = maxi(left, 1)
	var seconds := ceili(left / 1000.0)
	# The caption changes once a second; only the bar drains every frame.
	if seconds != _shown_seconds:
		_shown_seconds = seconds
		_label.text = "%s in %ds" % [caption, seconds]
		_label.add_theme_color_override("font_color", Tokens.DANGER if seconds <= ALARM_SECONDS else Tokens.GOLD_MID)
	_bar.queue_redraw()


func _draw_bar() -> void:
	var left := maxi(0, deadline_ms - Time.get_ticks_msec())
	var fraction := clampf(float(left) / maxf(_span, 1), 0.0, 1.0)
	var seconds := ceili(left / 1000.0)
	var colour := Tokens.DANGER if seconds <= ALARM_SECONDS else Tokens.GOLD_MID
	var r := Rect2(Vector2.ZERO, _bar.size)
	_bar.draw_style_box(UI.flat(Color(1, 1, 1, 0.08), 2), r)
	if fraction > 0.0:
		_bar.draw_style_box(UI.flat(colour, 2), Rect2(r.position, Vector2(r.size.x * fraction, r.size.y)))
