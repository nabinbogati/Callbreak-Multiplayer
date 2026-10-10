class_name DealOverlay
extends Control

## The dealing flourish, in three beats: the deck drops onto the felt, gets
## two quick riffles, then deals out — one card at a time round the table,
## each arcing to its seat with a spin and shrinking to the size of that
## seat's face-down fan. The player's own cards fly to the exact slot they will
## occupy and turn edge-on as they arrive; the hand finishes the flip as the
## real face-up card appears.
##
## Everything is drawn here each frame — only the deck and the handful of
## cards actually in the air, never 52 nodes.

## How many cards each seat has received so far, as they land.
signal progress(counts: Array)
signal finished

const DECK_WIDTH := 46.0

var dealer := 0
var viewer := 0
## Local start point (felt centre) and per-slot landing points.
var start := Vector2.ZERO
var seat_targets := {}
## The player's own hand slots, in hand order: `[centre, angle]`, local.
var hand_targets: Array = []
## The width of the player's hand cards and of an opponent's fan cards.
var hand_width := 58.0
var fan_width := 24.0

var _order: Array[int] = []
var _scale := 1.0
var _elapsed := 0.0
var _last_counts := [0, 0, 0, 0]


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(false)


## Seat receiving each of the 52 cards: starting just past the dealer, one card
## to each seat in turn, 13 rounds.
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
	return Motion.DEAL_TOTAL_MS * _scale / 1000.0


func _deal_start() -> float:
	return (Motion.DEAL_INTRO_MS + Motion.SHUFFLE_MS) * _scale / 1000.0


func _begin_of(i: int) -> float:
	return _deal_start() + i * Motion.DEAL_GAP_MS * _scale / 1000.0


func _flight() -> float:
	return Motion.DEAL_FLIGHT_MS * _scale / 1000.0


func _process(delta: float) -> void:
	_elapsed += delta
	var counts := [0, 0, 0, 0]
	for i in _order.size():
		if _elapsed >= _begin_of(i) + _flight():
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
	_draw_deck()
	var flying: Array[Transform2D] = []
	var player_cards := 0
	for i in _order.size():
		var slot := SeatView.slot_for(_order[i], viewer)
		var is_player := slot == SeatView.Slot.BOTTOM
		var player_index := -1
		if is_player:
			player_index = player_cards
			player_cards += 1
		var begin_t := _begin_of(i)
		if _elapsed < begin_t or _elapsed >= begin_t + _flight():
			continue
		var raw := (_elapsed - begin_t) / _flight()
		var target: Vector2
		var end_angle := 0.0
		var end_width := hand_width if is_player else fan_width
		if is_player and player_index < hand_targets.size():
			target = hand_targets[player_index][0]
			end_angle = hand_targets[player_index][1]
		else:
			target = seat_targets.get(slot, start)
			match slot:
				SeatView.Slot.LEFT: end_angle = -PI / 2
				SeatView.Slot.RIGHT: end_angle = PI / 2
		var spin := 0.25 if is_player else (PI if i % 2 == 0 else -PI)
		flying.append(_dealt_transform(raw, target, end_angle, end_width, is_player, spin))
	# The cards in the air: their shadows, then all of them in one draw call.
	var rect := _back_rect()
	for xf in flying:
		draw_set_transform_matrix(xf)
		CardView.back_shadow(self, rect)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var art := Draw.Batch.new()
	for xf in flying:
		art.transform = xf
		CardView.back_art(art, rect)
	art.flush(self)


## Every card in the deal is the same drawing, placed and scaled.
func _back_rect() -> Rect2:
	var size := Vector2(DECK_WIDTH, DECK_WIDTH * CardView.FACE_ASPECT)
	return Rect2(-size / 2.0, size)


## The deck at the centre: dropping in, riffling twice, then thinning as cards
## leave it.
func _draw_deck() -> void:
	var remaining := 0
	for i in _order.size():
		if _elapsed < _begin_of(i):
			remaining += 1
	if remaining <= 0:
		return
	var layers := clampi(ceili(remaining * 10.0 / 52.0), 1, 10)
	var w := DECK_WIDTH
	const STEP := 1.6
	var intro := Motion.DEAL_INTRO_MS * _scale / 1000.0
	var shuffle := Motion.SHUFFLE_MS * _scale / 1000.0
	var drop := 0.0
	var scale := 1.0
	var split := 0.0
	if _elapsed < intro:
		var t := Motion.enter(_elapsed / intro)
		drop = -w * 0.9 * (1.0 - t)
		scale = 1.25 - 0.25 * t
	elif _elapsed < intro + shuffle:
		# Two riffles: split apart, swing back together, twice.
		var u := (_elapsed - intro) / shuffle
		split = sin(fmod(u * 2.0, 1.0) * PI)
	var apart := w * 0.62 * split
	var rect := _back_rect()
	var art := Draw.Batch.new()
	for i in layers:
		var dx := 0.0
		var angle := 0.0
		if split > 0.001:
			# The halves interleave as they come back together.
			dx = -apart if i % 2 == 0 else apart
			angle = (-0.14 if i % 2 == 0 else 0.14) * split
		var center := start + Vector2(dx + i * STEP * 0.5, drop - i * STEP)
		var xf := Transform2D(angle, Vector2.ONE * scale, 0.0, center)
		if i == 0:
			# Only the bottom card casts a shadow, under the whole stack.
			draw_set_transform_matrix(xf)
			CardView.back_shadow(self, rect)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		art.transform = xf
		CardView.back_art(art, rect)
	art.flush(self)


## Where a dealt card is in its flight, as the transform its back is drawn
## with.
func _dealt_transform(raw: float, target: Vector2, end_angle: float, end_width: float, flip_at_end: bool,
		spin: float) -> Transform2D:
	var t := Motion.ease_out_cubic(raw)
	var path := TrickCluster.ThrowPath.new(start, target, 1.0, end_angle - spin, end_angle, 0.1)
	var w := DECK_WIDTH
	# Drawn at one fixed size and scaled, so every card in the air is the same
	# drawing.
	var width := w + (end_width - w) * t
	var scale := width / w * (1.0 + 0.1 * sin(PI * t))
	var squash := 1.0
	if flip_at_end and raw > 0.6:
		squash = cos((raw - 0.6) / 0.4 * PI / 2.0)
	return Transform2D(path.angle_at(t), Vector2(scale * squash, scale), 0.0, path.position_at(t))
