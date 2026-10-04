class_name HandFan
extends Control

## The player's own hand along the bottom of the table, held in a gentle arc.
##
## One gesture surface drives the whole fan, not one detector per card, which
## is what makes a tightly overlapped thirteen-card hand comfortable:
##
## * **Press** a card and it rises and grows, its neighbours parting so the
##   whole face shows.
## * **Slide sideways** and the preview follows the finger from card to card,
##   with a tick under the thumb at each one. Letting go after a slide never
##   plays anything — it is for reading the hand.
## * **Drag up** and the card follows the finger, tilting with its motion; it
##   is thrown once it passes the threshold or is flicked upward, and springs
##   back home otherwise.
## * **Tap** a playable card to play it (or, with "tap twice to play" on, to
##   raise it; a second tap plays).
##
## A card that cannot be played shakes, buzzes and reports itself through
## [signal illegal], so the table can say why.

## A card left the hand from [param global_center], at [param scale] of the
## fan's card size and turned [param angle] — so its flight starts exactly
## where the card was.
signal card_thrown(card: String, global_center: Vector2, scale: float, angle: float)
## The player tried to play a card the rules do not allow right now.
signal illegal(card: String)
## The player tried to throw a card while it is somebody else's turn.
signal not_your_turn

## Room above the resting cards for the playable ones to rise into.
const LIFT := 16.0
## How far a finger travels before a press becomes a slide or a drag.
const TOUCH_SLOP := 18.0
const FLING_SPEED := 850.0

enum Mode { IDLE, PRESSING, SCRUBBING, DRAGGING }

var card_width := 58.0
## Whether a legal card can be played right now — false while it is not this
## player's turn, so cards still preview but never leave the hand.
var interactive := false
## How many cards are revealed — fewer than the hand while it is being dealt.
var revealed := 13
## False while the deal is running: the cards are not the player's to handle
## until they are all down.
var gestures_enabled := true

var _cards: Array[String] = []
var _legal: Array = []
## Thrown but not yet gone from the hand (a networked table only removes a
## card once the server confirms the play).
var _hidden: Array = []
## card id → CardView
var _nodes := {}
## card id → _Pose (the animated slot each card glides between)
var _poses := {}

# Rest layout, recomputed with the hand.
var _laid: Array[String] = []
var _lefts: Array[float] = []
var _tops: Array[float] = []
var _angles: Array[float] = []

var _mode := Mode.IDLE
var _pointer_down := false
var _down := Vector2.ZERO
var _drag_anchor := Vector2.ZERO
var _selected := ""
var _drag := Vector2.ZERO
var _tilt := 0.0
var _last_pos := Vector2.ZERO
var _samples: Array = []
var _refused_this_gesture := false
## "Tap twice to play": the card raised by the first tap.
var _armed := ""
## The card springing home after a drag that did not throw.
var _returning := ""
var _return_from := Vector2.ZERO
var _return_tilt := 0.0
var _spring_t := 0.0
## The card shaking its head.
var _shake_id := ""
var _shake_t := 1.0
var _glow_alpha := 0.0
var _glow_t := 1.0
var _glow_on := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_relayout)


func card_height() -> float:
	return card_width * CardView.FACE_ASPECT


## The fan's own height: the cards, the room to rise and the arc's droop.
func fan_height() -> float:
	return card_height() + LIFT + card_height() * 0.08


func set_hand(cards: Array[String], legal: Array, is_interactive: bool, shown: int, hidden: Array = []) -> void:
	_cards = cards.duplicate()
	_legal = legal
	interactive = is_interactive
	revealed = shown
	_hidden = hidden
	custom_minimum_size.y = fan_height()
	# The turn moved on (or the card left): nothing stays raised or held.
	if not interactive:
		_armed = ""
	var live := _cards.filter(func(c): return not _hidden.has(c))
	if not _selected.is_empty() and not live.has(_selected):
		_clear_gesture()
	if not _armed.is_empty() and not live.has(_armed):
		_armed = ""
	if not gestures_enabled and _pointer_down:
		_clear_gesture()
	for id in _nodes.keys():
		if not live.has(id):
			_nodes[id].queue_free()
			_nodes.erase(id)
			_poses.erase(id)
	_relayout()


func _clear_gesture() -> void:
	_pointer_down = false
	_mode = Mode.IDLE
	_selected = ""
	_drag = Vector2.ZERO
	_tilt = 0.0


# ------------------------------------------------------------------ layout

func _relayout() -> void:
	_laid.clear()
	for c in _cards:
		if not _hidden.has(c):
			_laid.append(c)
	var n := _laid.size()
	var w := card_width
	var h := card_height()
	var max_width := size.x
	var fill := 0.0 if n <= 1 else maxf(0.0, (max_width - w) / (n - 1))
	# Portrait overlaps the classic way; landscape has width to spare and
	# spreads out, but always keeps at least a quarter of each card covered.
	var spacing := 0.0 if n <= 1 else (minf(w * 0.58, fill) if UI.portrait else minf(fill, w * 0.74))
	var start := (max_width - (w + spacing * (n - 1))) / 2.0
	var max_spread := 0.34 if UI.portrait else 0.24
	var step := 0.0 if n <= 1 else minf(0.04, max_spread / (n - 1))
	var depth := h * (0.08 if UI.portrait else 0.06)
	var mid := (n - 1) / 2.0
	_lefts.clear()
	_tops.clear()
	_angles.clear()
	for i in n:
		_lefts.append(start + spacing * i)
		_tops.append(LIFT + (0.0 if mid == 0 else depth * pow((i - mid) / mid, 2)))
		_angles.append((i - mid) * step)
	for i in n:
		var id := _laid[i]
		if not _nodes.has(id):
			var view := CardView.face(id, card_width)
			view.visible = false
			add_child(view)
			_nodes[id] = view
			_poses[id] = _Pose.new()
		var node: CardView = _nodes[id]
		if node.card_width != card_width:
			node.set_card_width(card_width)
		var visible_now := i < revealed
		if visible_now and not node.visible:
			# A card turning face up as it arrives: it swings in from edge-on,
			# finishing the flip the dealt card started in the air.
			_poses[id].reveal = 0.0
		node.visible = visible_now
	_update_targets(false)
	_set_glow(interactive and n > 0)
	set_process(true)


## Rest slots for each revealed card, in hand order, as global centres.
func slot_centers_global() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in _laid.size():
		out.append(get_global_transform() * _rest_center(i))
	return out


func slot_center_global(card: String) -> Variant:
	var i := _laid.find(card)
	return null if i < 0 else get_global_transform() * _rest_center(i)


func slot_angle(card: String) -> float:
	var i := _laid.find(card)
	return 0.0 if i < 0 else _angles[i]


func _rest_center(i: int) -> Vector2:
	return Vector2(_lefts[i] + card_width / 2.0, _tops[i] + card_height() / 2.0)


## The pose card [param i] should be in right now, before any drag offset:
## `[left, top, angle, scale, elevation]`.
func _visual_for(i: int) -> Array:
	var id := _laid[i]
	var legal := _legal.has(id)
	var selected_index := _laid.find(_selected) if not _selected.is_empty() else -1
	var selected := i == selected_index
	var h := card_height()
	var left := _lefts[i]
	var top := _tops[i]
	var angle := _angles[i]
	var scale := 1.0
	var elevation := 0.0
	if interactive and legal:
		top -= 14
	if interactive and not legal and not _legal.is_empty():
		top += 4
	if id == _armed and not selected:
		top -= h * 0.14
		elevation = 0.5
	if selected_index >= 0 and not selected:
		# Neighbours part around the previewed card, falling off with distance.
		var d := i - selected_index
		var falloff: float = {1: 1.0, 2: 0.45, 3: 0.15}.get(absi(d), 0.0)
		left += signi(d) * card_width * 0.3 * falloff
	if selected:
		var dragging := _mode == Mode.DRAGGING
		top -= 0.0 if dragging else h * 0.2
		scale = 1.12 if dragging else 1.18
		angle = 0.0
		elevation = 1.0
	return [left, top, angle, scale, elevation]


## Retargets every card's slot; they glide there over a short ease.
func _update_targets(snap: bool) -> void:
	var interacting := not _selected.is_empty() or not _armed.is_empty()
	var duration := Motion.scaled(Motion.PREVIEW_MS if interacting else Motion.SLOT_MS, Settings.animation_scale())
	for i in _laid.size():
		var pose: _Pose = _poses[_laid[i]]
		pose.retarget(_visual_for(i), duration, snap or not pose.placed)
		pose.placed = true
	_order_children()


## Paint order: the held/raised/returning card on top of its neighbours.
func _order_children() -> void:
	var order: Array = _laid.duplicate()
	for id in [_armed, _returning, _selected]:
		if not id.is_empty() and order.has(id):
			order.erase(id)
			order.append(id)
	for i in order.size():
		move_child(_nodes[order[i]], i)


func _process(delta: float) -> void:
	var busy := false
	for id in _poses:
		busy = _poses[id].advance(delta) or busy
	if not _returning.is_empty():
		_spring_t += delta
		busy = true
		if absf(_spring(_spring_t)) < 0.001 and _spring_t > 0.2:
			_returning = ""
	if _shake_t < 1.0:
		_shake_t = minf(_shake_t + delta / 0.42, 1.0)
		busy = true
	if _glow_t < 1.0:
		_glow_t = minf(_glow_t + delta / 2.1, 1.0)
		busy = true
	var fade := 1.0 if interactive and not _laid.is_empty() else 0.0
	if not is_equal_approx(_glow_alpha, fade):
		_glow_alpha = move_toward(_glow_alpha, fade, delta / 0.3)
		busy = true
	_render()
	queue_redraw()
	if not busy and _mode == Mode.IDLE:
		set_process(false)


## Displacement of a card springing home (1 → 0), an underdamped spring of
## stiffness 380 and damping 24 on a unit mass.
static func _spring(t: float) -> float:
	const OMEGA := 19.4936
	const ZETA := 0.61559
	var wd := OMEGA * sqrt(1.0 - ZETA * ZETA)
	return exp(-ZETA * OMEGA * t) * (cos(wd * t) + ZETA * OMEGA / wd * sin(wd * t))


func _render() -> void:
	var h := card_height()
	var selected_index := _laid.find(_selected) if not _selected.is_empty() else -1
	for i in _laid.size():
		var id := _laid[i]
		var node: CardView = _nodes[id]
		var pose: _Pose = _poses[id]
		var legal := _legal.has(id)
		var extra := Vector2.ZERO
		var tilt := 0.0
		if i == selected_index and _mode == Mode.DRAGGING:
			extra = _drag
			tilt = _tilt
		elif id == _returning:
			var k := _spring(_spring_t)
			extra = _return_from * k
			tilt = _return_tilt * k
		if id == _shake_id and _shake_t < 1.0:
			extra.x += sin(_shake_t * PI * 6.0) * (1.0 - _shake_t) * card_width * 0.12
		var flip := sin(Motion.ease_out_cubic(pose.reveal) * PI / 2.0) if pose.reveal < 1.0 else 1.0
		node.pivot_offset = Vector2(card_width, h) / 2.0
		node.position = Vector2(pose.value(0), pose.value(1)) + extra
		node.rotation = pose.value(2) + tilt
		node.scale = Vector2(pose.value(3) * flip, pose.value(3))
		node.elevation = pose.to[4]
		node.dimmed = interactive and not _legal.is_empty() and not legal
		node.highlighted = interactive and legal


## A warm glow rising behind the hand when it is the player's turn. It swells a
## few times as the turn arrives, then settles to a steady low light.
func _set_glow(active: bool) -> void:
	if active and not _glow_on:
		_glow_t = 0.0
	_glow_on = active


func _draw() -> void:
	if _glow_alpha <= 0.01:
		return
	var h := fan_height()
	var box := Rect2(-size.x * 0.05, -h * 0.6, size.x * 1.1, h * 1.7)
	var swell := 0.55 + 0.45 * absf(sin(_glow_t * PI * 6.0)) * (1.0 - _glow_t) if _glow_t < 1.0 else 0.55
	var center := Draw.align(box, Vector2(0, 0.45))
	var radius := 0.7 * minf(box.size.x, box.size.y)
	var pts := PackedVector2Array([box.position, Vector2(box.end.x, box.position.y), box.end,
			Vector2(box.position.x, box.end.y)])
	Draw.fill_radial(self, pts, center, radius, [Color(Tokens.TURN_GLOW, 0.3), Color(Tokens.TURN_GLOW, 0.0)], [],
			Color(1, 1, 1, swell * _glow_alpha))


# ---------------------------------------------------------------- gestures

func _hit(x: float) -> int:
	for i in range(mini(_laid.size(), revealed) - 1, -1, -1):
		if x >= _lefts[i] and x <= _lefts[i] + card_width:
			return i
	return -1


func _is_legal(id: String) -> bool:
	return _legal.has(id)


func _can_drag(id: String) -> bool:
	return interactive and _is_legal(id) and Settings.drag_to_play


func _drag_threshold() -> float:
	return card_height() * 0.42


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_down(event.position)
		else:
			_on_up(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _pointer_down:
		_on_move(event.position)
		accept_event()


func _on_down(pos: Vector2) -> void:
	if _pointer_down or not gestures_enabled:
		return
	_pointer_down = true
	_down = pos
	_last_pos = pos
	_refused_this_gesture = false
	_samples = [[Time.get_ticks_usec(), pos]]
	var i := _hit(pos.x)
	if i < 0:
		return
	_returning = ""
	_selected = _laid[i]
	_mode = Mode.PRESSING
	_update_targets(false)
	set_process(true)
	Haptics.tick()


func _on_move(pos: Vector2) -> void:
	var delta := pos - _last_pos
	_last_pos = pos
	_samples.append([Time.get_ticks_usec(), pos])
	if _samples.size() > 20:
		_samples.remove_at(0)
	if _selected.is_empty():
		return
	var moved := pos - _down
	match _mode:
		Mode.PRESSING:
			if moved.length() < TOUCH_SLOP:
				return
			var upward := -moved.y > absf(moved.x) * 0.9
			if upward and _can_drag(_selected):
				_begin_drag(_down)
				_update_drag(pos, delta)
			else:
				_mode = Mode.SCRUBBING
				_scrub(pos)
		Mode.SCRUBBING:
			# Rising well above the fan from a scrub picks the card up.
			var rise := _down.y - pos.y
			if rise > card_width * 0.5 and _can_drag(_selected):
				_begin_drag(Vector2(pos.x, _down.y))
				_update_drag(pos, delta)
				return
			if rise > _drag_threshold():
				_refuse(_selected)
			_scrub(pos)
		Mode.DRAGGING:
			_update_drag(pos, delta)


func _begin_drag(anchor: Vector2) -> void:
	_drag_anchor = anchor
	_armed = ""
	_mode = Mode.DRAGGING
	_update_targets(false)


func _update_drag(pos: Vector2, delta: Vector2) -> void:
	if _selected.is_empty():
		return
	_drag = pos - _drag_anchor
	_tilt = _tilt * 0.6 + clampf(delta.x * 0.03, -0.32, 0.32) * 0.4
	set_process(true)
	if -_drag.y >= _drag_threshold():
		_throw(_selected)


func _scrub(pos: Vector2) -> void:
	var i := _hit(pos.x)
	if i < 0 or _laid[i] == _selected:
		return
	_selected = _laid[i]
	_update_targets(false)
	Haptics.tick()


## Upward speed over the last tenth of a second, in px/s (positive = up).
func _upward_velocity() -> float:
	if _samples.size() < 2:
		return 0.0
	var last: Array = _samples[_samples.size() - 1]
	var first: Array = last
	for s in _samples:
		if last[0] - s[0] <= 100000:
			first = s
			break
	var dt: float = (last[0] - first[0]) / 1000000.0
	return 0.0 if dt <= 0.0 else -(last[1].y - first[1].y) / dt


func _on_up(_pos: Vector2) -> void:
	if not _pointer_down:
		return
	_pointer_down = false
	var selected := _selected
	var mode := _mode
	if selected.is_empty() or not _laid.has(selected):
		_reset()
		return
	match mode:
		Mode.PRESSING:
			_tap(selected)
		Mode.DRAGGING:
			var flung := _upward_velocity() > FLING_SPEED and -_drag.y > _drag_threshold() * 0.3
			if flung:
				_throw(selected)
			else:
				_spring_home(selected)
		_:
			_reset()


func _tap(id: String) -> void:
	if not interactive:
		_reset()
		return
	if not _is_legal(id):
		_refuse(id)
		_reset()
		return
	if Settings.tap_twice_to_play and _armed != id:
		_armed = id
		Haptics.tick()
		_reset()
		return
	_throw(id)


func _throw(id: String) -> void:
	var i := _laid.find(id)
	if i < 0:
		_reset()
		return
	var pose := _visual_for(i)
	var center := Vector2(pose[0] + card_width / 2.0, pose[1] + card_height() / 2.0) + _drag
	_pointer_down = false
	Haptics.tap()
	var angle: float = pose[2] + _tilt
	_armed = ""
	_reset()
	card_thrown.emit(id, get_global_transform() * center, pose[3], angle)


func _refuse(id: String) -> void:
	if _refused_this_gesture:
		return
	_refused_this_gesture = true
	_shake_id = id
	_shake_t = 0.0
	set_process(true)
	Haptics.nope()
	if interactive:
		illegal.emit(id)
	else:
		not_your_turn.emit()


func _spring_home(id: String) -> void:
	_returning = id
	_return_from = _drag
	_return_tilt = _tilt
	_spring_t = 0.0
	_reset()


func _reset() -> void:
	_mode = Mode.IDLE
	_selected = ""
	_drag = Vector2.ZERO
	_tilt = 0.0
	_update_targets(false)
	set_process(true)


## One card's slot, gliding to each new target (slots closing up after a
## throw, a card rising for preview) instead of jumping. Values are
## `[left, top, angle, scale, elevation]`.
class _Pose:
	extends RefCounted

	var from: Array = [0.0, 0.0, 0.0, 1.0, 0.0]
	var to: Array = [0.0, 0.0, 0.0, 1.0, 0.0]
	var t := 1.0
	var duration := 0.22
	var placed := false
	## 0 → 1 as a dealt card turns face up.
	var reveal := 1.0

	func retarget(target: Array, d: float, snap: bool) -> void:
		if snap:
			from = target.duplicate()
			to = target.duplicate()
			t = 1.0
			return
		if target == to:
			return
		from = [value(0), value(1), value(2), value(3), value(4)]
		to = target.duplicate()
		duration = maxf(d, 0.001)
		t = 0.0

	func value(i: int) -> float:
		return lerpf(from[i], to[i], Motion.emphasized(t))

	func advance(delta: float) -> bool:
		var moving := false
		if t < 1.0:
			t = minf(t + delta / duration, 1.0)
			moving = true
		if reveal < 1.0:
			reveal = minf(reveal + delta / Motion.scaled(Motion.REVEAL_MS, Settings.animation_scale()), 1.0)
			moving = true
		return moving
