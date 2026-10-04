class_name HandFan
extends Control

## The player's own hand along the bottom of the table: overlapping cards,
## legal ones lifted and playable, illegal ones dimmed and inert. Tap a legal
## card to throw it, or (with "Drag to play" on) drag it up past 30% of its
## height. Holding a card zooms it above its neighbours so its rank and suit
## are unmistakable before it is committed.

## A card left the hand, from [param global_pos] — where the finger released
## it, so its flight to the table starts there.
signal card_thrown(card: String, global_pos: Vector2)

const LIFT := 14.0
const ZOOM := 1.25

var card_width := 54.0
var interactive := false
## How many cards are visible — fewer than the hand while it is being dealt.
var revealed := 13

var _cards: Array[String] = []
var _legal: Array = []
var _nodes := {}
var _pressed := ""
var _press_pos := Vector2.ZERO
var _drag := Vector2.ZERO
var _dragging := false
var _thrown := false
var _snap: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_layout.bind(false))


func card_height() -> float:
	return card_width * CardView.FACE_ASPECT


func set_hand(cards: Array[String], legal: Array, is_interactive: bool, shown: int) -> void:
	var changed_cards := cards != _cards
	var newly_shown := shown > revealed
	_cards = cards.duplicate()
	_legal = legal
	interactive = is_interactive
	var previous_revealed := revealed
	revealed = shown
	custom_minimum_size.y = LIFT + card_height()
	for id in _nodes.keys():
		if not _cards.has(id):
			_nodes[id].queue_free()
			_nodes.erase(id)
	for i in _cards.size():
		var id := _cards[i]
		if not _nodes.has(id):
			var view := CardView.face(id, card_width)
			add_child(view)
			_nodes[id] = view
		var node: CardView = _nodes[id]
		var visible_now := i < revealed
		if visible_now and not node.visible and newly_shown and i >= previous_revealed:
			_pop_in(node)
		node.visible = visible_now
		node.dimmed = interactive and not _legal.has(id)
	if not _pressed.is_empty() and (not _cards.has(_pressed) or not _can_play(_pressed)):
		_release_press()
	_layout(not changed_cards)


func _pop_in(node: CardView) -> void:
	node.modulate.a = 0.0
	node.scale = Vector2(0.85, 0.85)
	var t := create_tween().set_parallel()
	t.tween_property(node, "modulate:a", 1.0, 0.16)
	t.tween_property(node, "scale", Vector2.ONE, 0.16)


## Slot spacing: a traditional overlapping fan in portrait; in landscape it
## spreads toward the edges but always keeps 30% of each card overlapped.
func _spacing() -> float:
	var n := _cards.size()
	if n <= 1:
		return 0.0
	var fill := maxf(0.0, (size.x - card_width) / (n - 1))
	return minf(card_width * 0.55, fill) if UI.portrait else minf(fill, card_width * 0.7)


## The resting top-left of the card at [param index].
func _rest_position(index: int) -> Vector2:
	var spacing := _spacing()
	var fan_width := card_width + spacing * (_cards.size() - 1)
	var id := _cards[index]
	var lifted := interactive and _legal.has(id)
	return Vector2((size.x - fan_width) / 2.0 + spacing * index, 0.0 if lifted else LIFT)


## Global centre of each card's resting slot, in hand order.
func slot_centers_global() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in _cards.size():
		out.append(get_global_rect().position + _rest_position(i) + Vector2(card_width, card_height()) / 2.0)
	return out


func slot_center_global(card: String) -> Variant:
	var i := _cards.find(card)
	if i < 0:
		return null
	return slot_centers_global()[i]


func _layout(animate: bool) -> void:
	var scale_ms := Settings.animation_scale()
	for i in _cards.size():
		var id := _cards[i]
		var node: CardView = _nodes[id]
		var target := _rest_position(i)
		if id == _pressed:
			target += _drag
		node.z_index = 10 if id == _pressed else 0
		if animate and node.position != target and id != _pressed:
			var t := node.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			t.tween_property(node, "position", target, 0.18 * scale_ms)
		else:
			node.position = target
	# Paint order follows hand order; the held card is lifted by z_index.
	for i in _cards.size():
		move_child(_nodes[_cards[i]], i)


func _card_at(pos: Vector2) -> String:
	for i in range(mini(revealed, _cards.size()) - 1, -1, -1):
		var node: CardView = _nodes[_cards[i]]
		if Rect2(node.position, node.size).has_point(pos):
			return _cards[i]
	return ""


func _can_play(id: String) -> bool:
	return interactive and _legal.has(id)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var id := _card_at(event.position)
			if id.is_empty() or not _can_play(id):
				return
			_pressed = id
			_press_pos = event.position
			_drag = Vector2.ZERO
			_dragging = false
			_thrown = false
			_zoom(id, true)
			_layout(false)
			accept_event()
		elif not _pressed.is_empty():
			var id := _pressed
			accept_event()
			if _thrown:
				return
			if not _dragging:
				# A tap: throw it from where the card sits.
				_throw(id)
			else:
				_snap_back()
	elif event is InputEventMouseMotion and not _pressed.is_empty() and not _thrown:
		var moved: Vector2 = event.position - _press_pos
		if not _dragging and moved.length() > 10.0:
			_dragging = true
		if _dragging:
			if not Settings.drag_to_play:
				return
			_drag = moved
			_layout(false)
			# Thrown the instant the drag crosses the line, not on lift-off.
			if -_drag.y >= card_height() * 0.3:
				_throw(_pressed)
		accept_event()


func _zoom(id: String, on: bool) -> void:
	if not _nodes.has(id):
		return
	var node: CardView = _nodes[id]
	node.pivot_offset = Vector2(node.size.x / 2.0, node.size.y)
	var t := node.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "scale", Vector2.ONE * (ZOOM if on else 1.0), 0.14 * Settings.animation_scale())


func _throw(id: String) -> void:
	_thrown = true
	var node: CardView = _nodes.get(id)
	var center := get_global_rect().position + Vector2(card_width, card_height()) / 2.0
	if node != null:
		center = node.get_global_rect().get_center()
		node.visible = false
	_pressed = ""
	_drag = Vector2.ZERO
	card_thrown.emit(id, center)


func _snap_back() -> void:
	var id := _pressed
	_zoom(id, false)
	_pressed = ""
	_drag = Vector2.ZERO
	if _snap != null:
		_snap.kill()
	var node: CardView = _nodes.get(id)
	var i := _cards.find(id)
	if node != null and i >= 0:
		node.z_index = 0
		_snap = node.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_snap.tween_property(node, "position", _rest_position(i), 0.22 * Settings.animation_scale())


func _release_press() -> void:
	if not _pressed.is_empty():
		_zoom(_pressed, false)
	_pressed = ""
	_drag = Vector2.ZERO
	_dragging = false
