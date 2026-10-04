class_name TrickCluster
extends Control

## The cards on the felt for the trick in progress, laid out in a fixed
## diamond around the felt's centre: each rests toward the side of whoever
## threw it, so cards already down never shift as later ones join. Each card
## travels in a straight line from the seat that played it (or from where the
## player's finger released it), the currently-leading card glows, and once the
## trick is decided all four sweep off toward the winner.
##
## Sits above the hand in the table's paint order, so the player's own throw is
## visible for its whole flight.

const ENTRANCE := 0.52
const COLLECT := 0.46
const FLIGHT_TILT := [0.12, -0.18, -0.12, 0.18]

var card_width := 44.0
## card id → {node, slot, settled}
var _cards := {}
var _initialised := false
var _collecting := false
var _rest_center := Vector2.ZERO
var _anchors := {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func card_height() -> float:
	return card_width * CardView.FACE_ASPECT


## Where a card thrown from [param slot] comes to rest (its centre).
func rest_for(slot: int) -> Vector2:
	var dx := card_width * 1.05
	var dy := card_height() * 0.55
	match slot:
		SeatView.Slot.BOTTOM: return _rest_center + Vector2(0, dy)
		SeatView.Slot.LEFT: return _rest_center + Vector2(-dx, 0)
		SeatView.Slot.TOP: return _rest_center + Vector2(0, -dy)
	return _rest_center + Vector2(dx, 0)


func _anchor_for(slot: int, reach: float) -> Vector2:
	if _anchors.has(slot):
		return _anchors[slot]
	match slot:
		SeatView.Slot.BOTTOM: return _rest_center + Vector2(0, reach)
		SeatView.Slot.LEFT: return _rest_center + Vector2(-reach, 0)
		SeatView.Slot.TOP: return _rest_center + Vector2(0, -reach)
	return _rest_center + Vector2(reach, 0)


## Brings the felt in line with [param plays]. [param origins] maps card ids
## to local start points for throws this device made; everything else flies
## from its seat's [param anchors] entry. [param winner] is the seat taking a
## finished trick, or -1 while it is still being played.
func sync(plays: Array, viewer: int, winner: int, anchors: Dictionary, origins: Dictionary,
		rest_center: Vector2, width: float) -> void:
	_anchors = anchors
	var relayout := rest_center != _rest_center or width != card_width
	_rest_center = rest_center
	card_width = width
	var ids := plays.map(func(p): return p["card"])
	for id in _cards.keys():
		if not ids.has(id):
			_cards[id]["node"].queue_free()
			_cards.erase(id)
	if plays.is_empty():
		_collecting = false

	var leading := Rules.trick_winner(plays) if not plays.is_empty() else -1
	for p in plays:
		var id: String = p["card"]
		var slot := SeatView.slot_for(p["seat"], viewer)
		if not _cards.has(id):
			var node := CardView.face(id, card_width)
			add_child(node)
			_cards[id] = {"node": node, "slot": slot, "settled": false}
			if not _initialised:
				# First look at a live trick (a rejoin landing mid-hand): the cards
				# are already down, so they do not fly in again.
				_place(id)
			else:
				_fly_in(id, origins.get(id))
		elif relayout and _cards[id]["settled"] and not _collecting:
			_place(id)
		(_cards[id]["node"] as CardView).highlighted = p["seat"] == leading
	_initialised = true

	if winner >= 0 and not _collecting:
		_collecting = true
		var target := _anchor_for(SeatView.slot_for(winner, viewer), card_width * 2.4)
		var delay := ENTRANCE * Settings.animation_scale()
		get_tree().create_timer(delay).timeout.connect(_collect.bind(target))
	elif winner < 0:
		_collecting = false


func _place(id: String) -> void:
	var entry: Dictionary = _cards[id]
	var node: CardView = entry["node"]
	node.set_card_width(card_width)
	node.position = rest_for(entry["slot"]) - node.size / 2.0
	node.rotation = 0
	node.scale = Vector2.ONE
	node.modulate.a = 1.0
	entry["settled"] = true


func _fly_in(id: String, origin) -> void:
	var entry: Dictionary = _cards[id]
	var node: CardView = entry["node"]
	var slot: int = entry["slot"]
	var own_throw: bool = origin != null
	var start: Vector2 = origin if own_throw else _anchor_for(slot, card_width * 1.8)
	var rest := rest_for(slot)
	var duration := ENTRANCE * Settings.animation_scale()
	node.position = start - node.size / 2.0
	if own_throw:
		# Already visible in the hand when it left, so it stays solid.
		node.modulate.a = 1.0
		node.scale = Vector2.ONE
	else:
		node.modulate.a = 0.0
		node.scale = Vector2(0.7, 0.7)
	node.rotation = FLIGHT_TILT[slot]
	var t := node.create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "position", rest - node.size / 2.0, duration)
	t.tween_property(node, "rotation", 0.0, duration)
	t.tween_property(node, "modulate:a", 1.0, duration)
	t.tween_property(node, "scale", Vector2.ONE, duration)
	t.chain().tween_callback(func():
		if _cards.has(id):
			_cards[id]["settled"] = true)


func _collect(target: Vector2) -> void:
	if not _collecting:
		return
	var duration := COLLECT * Settings.animation_scale()
	for id in _cards:
		var node: CardView = _cards[id]["node"]
		var t := node.create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		t.tween_property(node, "position", target - node.size / 2.0, duration)
		t.tween_property(node, "scale", Vector2.ONE * 0.45, duration)
		t.tween_property(node, "modulate:a", 0.0, duration)
