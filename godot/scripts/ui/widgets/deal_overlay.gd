class_name DealOverlay
extends Control

## The dealing flourish: a deck at the felt's centre deals face-down cards one
## at a time, clockwise from the dealer's left, 13 rounds. Each flies to its
## seat (the player's own land on the exact hand slot the real card is about to
## occupy) and fades as the real card is revealed underneath, so every hand
## fills in card by card. Everything is drawn here; nothing is a node.

## How many cards each seat has received so far, as they land.
signal progress(counts: Array)
signal finished

const CARD_GAP := 0.055
const FLIGHT := 0.42
const FADE := 0.22
const CARD_WIDTH := 44.0
const MAX_LAYERS := 12

var dealer := 0
var viewer := 0
## Local start point (felt centre) and per-slot landing points.
var start := Vector2.ZERO
var seat_targets := {}
## The player's own hand slots, in hand order, local coordinates.
var hand_targets: Array = []

var _order: Array[int] = []
var _scale := 1.0
var _elapsed := 0.0
var _last_counts := [0, 0, 0, 0]


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func begin(dealer_in: int, viewer_in: int) -> void:
	dealer = dealer_in
	viewer = maxi(viewer_in, 0)
	_scale = Settings.animation_scale()
	_order.clear()
	for round_i in 13:
		for d in range(1, 5):
			_order.append((dealer + d) % 4)
	_elapsed = 0.0
	_last_counts = [0, 0, 0, 0]
	Audio.play_deal()
	set_process(true)


func total_time() -> float:
	return (CARD_GAP * 52 + FLIGHT + FADE) * _scale


func _process(delta: float) -> void:
	_elapsed += delta
	var counts := [0, 0, 0, 0]
	for i in _order.size():
		if _elapsed >= (i * CARD_GAP + FLIGHT) * _scale:
			counts[_order[i]] += 1
	if counts != _last_counts:
		_last_counts = counts
		progress.emit(counts)
	queue_redraw()
	if _elapsed >= total_time():
		set_process(false)
		Audio.stop_deal()
		finished.emit()


func _exit_tree() -> void:
	Audio.stop_deal()


func _draw() -> void:
	var w := CARD_WIDTH
	var h := w * CardView.BACK_ASPECT
	# The deck thins in step with the deal.
	var remaining := 0
	for i in 52:
		if _elapsed < i * CARD_GAP * _scale:
			remaining += 1
	if remaining > 0:
		var layers := clampi(remaining * MAX_LAYERS / 52, 1, MAX_LAYERS)
		for i in range(layers - 1, -1, -1):
			CardView.paint_back(self, Rect2(start - Vector2(w, h) / 2.0 + Vector2(i, i) * 2.0, Vector2(w, h)),
					false, i == 0)

	var own_seen := 0
	for i in _order.size():
		var seat := _order[i]
		var slot := SeatView.slot_for(seat, viewer)
		var target: Vector2
		if slot == SeatView.Slot.BOTTOM and own_seen < hand_targets.size():
			target = hand_targets[own_seen]
		else:
			target = seat_targets.get(slot, start)
		if slot == SeatView.Slot.BOTTOM:
			own_seen += 1
		var begin_t := i * CARD_GAP * _scale
		var end_t := begin_t + FLIGHT * _scale
		var fade_end := end_t + FADE * _scale
		if _elapsed < begin_t or _elapsed >= fade_end:
			continue
		var t := clampf((_elapsed - begin_t) / (end_t - begin_t), 0.0, 1.0)
		var alpha := 1.0 if _elapsed < end_t else 1.0 - clampf((_elapsed - end_t) / (fade_end - end_t), 0.0, 1.0)
		var end_rot := 0.0
		match slot:
			SeatView.Slot.LEFT: end_rot = -PI / 2
			SeatView.Slot.RIGHT: end_rot = PI / 2
		# A slight travel tilt off the deck, turning to the seat's own angle.
		draw_set_transform(start.lerp(target, t), end_rot * t + 0.2 * (1.0 - t), Vector2.ONE)
		var r := Rect2(-Vector2(w, h) / 2.0, Vector2(w, h))
		if alpha < 1.0:
			_paint_faded(r, alpha)
		else:
			CardView.paint_back(self, r, false, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _paint_faded(r: Rect2, alpha: float) -> void:
	var palette := Settings.palette()
	var stops: Array = palette["card_back"].map(func(c): return Color(c, alpha))
	Draw.rounded_rect(self, r, r.size.x * 8.0 / 72.0, stops, true, Color(Tokens.GOLD_BORDER, 0.7 * alpha),
			r.size.x * 1.5 / 72.0)
