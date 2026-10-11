class_name DealOverlay
extends Control

## The deal: one card at a time round the table, each sliding in a straight
## line from the deck at the felt's centre to its seat, shrinking to the size
## of that seat's face-down fan. The player's own cards slide to the exact slot
## they will occupy, where the face-up card takes over as each lands.
##
## Only the handful of cards actually in the air are on screen, as a small pool
## of card backs painted once and moved by their transforms — never 52 nodes,
## and nothing repainted while they fly. A card waiting in the pool is made
## fully transparent rather than hidden: the renderer skips it all the same,
## and showing a hidden item again would repaint it.

## How many cards each seat has received so far, as they land.
signal progress(counts: Array)
signal finished

const DECK_WIDTH := 46.0
## The most cards in the air at once: a flight spans this many gaps.
const POOL := Motion.DEAL_FLIGHT_MS / Motion.DEAL_GAP_MS + 2

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
var _deck := _Deck.new()
var _flying: Array[CardView] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	add_child(_deck)
	for i in POOL:
		var card := CardView.back(DECK_WIDTH)
		card.modulate.a = 0.0
		add_child(card)
		_flying.append(card)


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
	_place()
	set_process(true)


func total_time() -> float:
	return Motion.DEAL_TOTAL_MS * _scale / 1000.0


func _begin_of(i: int) -> float:
	return i * Motion.DEAL_GAP_MS * _scale / 1000.0


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
	_place()
	if _elapsed >= total_time():
		set_process(false)
		Audio.stop_deal()
		finished.emit()


func _exit_tree() -> void:
	Audio.stop_deal()


## Puts the deck and every card in the air where they are now.
func _place() -> void:
	var remaining := 0
	var used := 0
	var player_cards := 0
	for i in _order.size():
		var slot := SeatView.slot_for(_order[i], viewer)
		var is_player := slot == SeatView.Slot.BOTTOM
		var player_index := player_cards
		if is_player:
			player_cards += 1
		var begin_t := _begin_of(i)
		if _elapsed < begin_t:
			remaining += 1
			continue
		if _elapsed >= begin_t + _flight() or used >= _flying.size():
			continue
		var target: Vector2 = seat_targets.get(slot, start)
		var end_angle := 0.0
		if is_player and player_index < hand_targets.size():
			target = hand_targets[player_index][0]
			end_angle = hand_targets[player_index][1]
		elif slot == SeatView.Slot.LEFT:
			end_angle = -PI / 2
		elif slot == SeatView.Slot.RIGHT:
			end_angle = PI / 2
		var t := Motion.decelerate((_elapsed - begin_t) / _flight())
		var width := DECK_WIDTH + ((hand_width if is_player else fan_width) - DECK_WIDTH) * t
		var card := _flying[used]
		used += 1
		card.modulate.a = 1.0
		card.position = start.lerp(target, t) - card.size / 2.0
		card.rotation = end_angle * t
		card.scale = Vector2.ONE * width / DECK_WIDTH
	for i in range(used, _flying.size()):
		_flying[i].modulate.a = 0.0
	_deck.visible = remaining > 0
	_deck.position = start - _deck.size / 2.0


## The deck waiting at the centre: a few backs squared up, drawn once.
class _Deck:
	extends Control

	const LAYERS := 3
	const STEP := 1.6

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size = Vector2(DECK_WIDTH, DECK_WIDTH * CardView.FACE_ASPECT)
		Settings.changed.connect(queue_redraw)

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		CardView.back_shadow(self, rect)
		for i in LAYERS:
			draw_set_transform(Vector2(i * STEP * 0.5, -i * STEP))
			CardView.back_shapes(rect).draw(self)
		draw_set_transform(Vector2.ZERO)
