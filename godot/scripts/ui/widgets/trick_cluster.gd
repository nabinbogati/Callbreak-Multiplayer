class_name TrickCluster
extends Control

## The cards on the felt for the trick in progress, laid out in a fixed
## diamond around the felt's centre: each card rests toward the side of
## whoever threw it, so cards already down never shift as later ones join.
##
## Cards arrive along a [ThrowPath] from the seat that played them — face
## down from an opponent, turning over in mid-air — and rest at a slight,
## card-specific angle the way real throws land. The card currently winning
## glows and sits on top. Once the trick is decided the cards slide together
## onto the winner's card, which pulses, and the stack sweeps away to the
## winner's seat.
##
## The player's own throws start the moment the finger lets go ([method
## throw_card]) and hold, landed, until the table confirms the play — on a
## networked table that is a round trip away. One the table never confirms is
## dropped and [signal throw_refused] hands it back to the hand.
##
## Sits above the hand in the table's paint order, so the player's own throw is
## visible for its whole flight.

signal throw_refused(card: String)

## How long a thrown card may wait, landed, for the table to confirm it before
## it is treated as refused.
const CONFIRM_TIMEOUT := 2.5

var card_width := 44.0
## card id → _Thrown
var _cards := {}
var _order: Array = []
var _initialised := false
var _winner := -1
var _collecting := false
var _collect_wait := 0.0
var _rest_center := Vector2.ZERO
var _anchors := {}
var _viewer := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func card_height() -> float:
	return card_width * CardView.FACE_ASPECT


## Where a card thrown from [param slot] comes to rest (its centre).
func rest_for(slot: int) -> Vector2:
	var dx := card_width * 1.02
	var dy := card_height() * 0.54
	match slot:
		SeatView.Slot.BOTTOM: return _rest_center + Vector2(0, dy)
		SeatView.Slot.LEFT: return _rest_center + Vector2(-dx, 0)
		SeatView.Slot.TOP: return _rest_center + Vector2(0, -dy)
	return _rest_center + Vector2(dx, 0)


## The small resting tilt of [param card] — stable per card, so the same card
## always lands the same way.
static func rest_angle(card: String) -> float:
	var h := 0
	for i in card.length():
		h = (h * 31 + card.unicode_at(i)) & 0x7fffffff
	return ((h % 1000) / 1000.0 - 0.5) * 0.16


static func _spin_for(slot: int) -> float:
	match slot:
		SeatView.Slot.LEFT: return -0.9
		SeatView.Slot.TOP: return 0.7
		SeatView.Slot.RIGHT: return 0.9
	return 0.0


func _anchor_for(slot: int, reach: float) -> Vector2:
	if _anchors.has(slot):
		return _anchors[slot]
	match slot:
		SeatView.Slot.BOTTOM: return _rest_center + Vector2(0, reach)
		SeatView.Slot.LEFT: return _rest_center + Vector2(-reach, 0)
		SeatView.Slot.TOP: return _rest_center + Vector2(0, -reach)
	return _rest_center + Vector2(reach, 0)


static func _trick_scale() -> float:
	return Motion.trick_scale(Settings.animation_scale())


## Cards this device threw that the table has not confirmed yet.
func pending_ids() -> Array:
	var out := []
	for id in _cards:
		if not _cards[id].confirmed:
			out.append(id)
	return out


## The player's own throw, starting where the card left the hand:
## [param origin] (local), at [param start_scale] of the felt's card size and
## turned [param start_angle].
func throw_card(card: String, origin: Vector2, start_scale: float, start_angle: float) -> void:
	if _cards.has(card):
		return
	var c := _Thrown.new(card, SeatView.Slot.BOTTOM, CardView.face(card, card_width))
	c.confirmed = false
	c.path = ThrowPath.new(origin, rest_for(SeatView.Slot.BOTTOM), start_scale, start_angle, rest_angle(card))
	_add(c)
	set_process(true)


## Brings the felt in line with [param plays]. [param origins] maps card ids
## to where a play of the viewer's own seat should start —
## `{"pos": Vector2, "scale": float, "angle": float}` — for plays that arrive
## with no gesture (autoplay); everything else flies from its seat's
## [param anchors] entry. [param winner] is the seat taking a finished trick,
## or -1 while it is still being played.
func sync(plays: Array, viewer: int, winner: int, anchors: Dictionary, origins: Dictionary,
		rest_center: Vector2, width: float) -> void:
	_anchors = anchors
	_viewer = viewer
	var relayout := rest_center != _rest_center or width != card_width
	_rest_center = rest_center
	card_width = width
	var ids := plays.map(func(p): return p["card"])
	for id in _cards.keys():
		var c: _Thrown = _cards[id]
		if not ids.has(id) and c.confirmed:
			_remove(id)
	if relayout:
		for id in _cards:
			_cards[id].node.set_card_width(card_width)
			_aim(_cards[id])

	var leading := Rules.trick_winner(plays) if not plays.is_empty() else -1
	for p in plays:
		var id: String = p["card"]
		var slot := SeatView.slot_for(p["seat"], viewer)
		if _cards.has(id):
			_cards[id].confirmed = true
		else:
			var c := _Thrown.new(id, slot, CardView.face(id, card_width))
			c.seat = p["seat"]
			_aim(c)
			var o = origins.get(id)
			if o != null:
				c.path = ThrowPath.new(o["pos"], rest_for(slot), o["scale"], o["angle"], rest_angle(id))
				c.flip = false
			if not _initialised:
				# First look at a live trick (a rejoin landing mid-hand): the
				# cards are already down, so they do not fly in again.
				c.entrance = 1.0
			_add(c)
		_cards[id].seat = p["seat"]
		_cards[id].node.highlighted = p["seat"] == leading
	_initialised = true
	# The live leader paints on top; the rest keep the order they landed in.
	var on_top := _order.filter(func(id): return _cards[id].seat == leading and _cards[id].confirmed)
	_order = _order.filter(func(id): return not on_top.has(id)) + on_top
	for i in _order.size():
		move_child(_cards[_order[i]].node, i)

	if winner >= 0 and _winner < 0:
		# Let the trick-completing card (thrown at the same instant the winner
		# was decided) land before anything starts to gather.
		_winner = winner
		_collecting = false
		_collect_wait = Motion.scaled(Motion.THROW_MS, _trick_scale())
		_aim_collect()
	elif winner < 0:
		_winner = -1
		_collecting = false
	set_process(true)
	_render()


func _add(c: _Thrown) -> void:
	_cards[c.card] = c
	_order.append(c.card)
	add_child(c.node)


func _remove(id: String) -> void:
	_cards[id].node.queue_free()
	_cards.erase(id)
	_order.erase(id)


## Points an opponent's (or a rejoined) card along its throw from its seat.
func _aim(c: _Thrown) -> void:
	var rest := rest_for(c.slot)
	var angle := rest_angle(c.card)
	if c.path == null or c.slot != SeatView.Slot.BOTTOM:
		var mine := c.slot == SeatView.Slot.BOTTOM
		# Opponents' cards start small (they come out of a small face-down fan)
		# with a spin; the player's own start at hand size, flat.
		c.path = ThrowPath.new(_anchor_for(c.slot, card_width * 1.8), rest, 1.0 if mine else 0.55,
				0.0 if mine else angle + _spin_for(c.slot), angle)
		c.flip = not mine
	else:
		c.path.end = rest


## Where the decided trick gathers (the winner's card) and sweeps to.
func _aim_collect() -> void:
	if _winner < 0:
		return
	var winner_slot := SeatView.slot_for(_winner, _viewer)
	var winner_card := ""
	for id in _cards:
		if _cards[id].seat == _winner:
			winner_card = id
	var gather := rest_for(winner_slot)
	var gather_angle := rest_angle(winner_card) if winner_card != "" else 0.0
	var collect := _anchor_for(winner_slot, card_width * 2.4)
	for id in _cards:
		var c: _Thrown = _cards[id]
		c.gather = gather if winner_card != "" else c.path.end
		c.gather_angle = gather_angle if winner_card != "" else c.path.end_angle
		c.collect_to = collect
		c.is_winner = id == winner_card


func _process(delta: float) -> void:
	var scale := _trick_scale()
	var throw_time := Motion.scaled(Motion.THROW_MS, scale)
	var collect_time := Motion.scaled(Motion.GATHER_MS + Motion.SWEEP_MS, scale)
	var busy := false
	for id in _cards.keys():
		var c: _Thrown = _cards[id]
		c.age += delta
		if c.entrance < 1.0:
			c.entrance = minf(c.entrance + delta / maxf(throw_time, 0.001), 1.0)
			busy = true
		if not c.confirmed:
			busy = true
			if c.age >= CONFIRM_TIMEOUT and c.entrance >= 1.0:
				_remove(id)
				throw_refused.emit(id)
				continue
		if _collecting and c.entrance >= 1.0 and c.collect < 1.0:
			c.collect = minf(c.collect + delta / maxf(collect_time, 0.001), 1.0)
			busy = true
	if _winner >= 0 and not _collecting:
		_collect_wait -= delta
		busy = true
		if _collect_wait <= 0.0:
			_collecting = true
			_aim_collect()
	_render()
	if not busy and not _collecting:
		set_process(false)


func _render() -> void:
	for id in _cards:
		_cards[id].render(card_width)


## The path a thrown card travels: a gentle arc (bowing to the right of its
## direction of travel, so every seat's throws swirl the same way), turning
## from [member start_angle] to [member end_angle], and scaling from
## [member start_scale] to 1 with a slight rise mid-air — the "toss".
class ThrowPath:
	extends RefCounted

	var start: Vector2
	var end: Vector2
	var start_scale: float
	var start_angle: float
	var end_angle: float
	## How far the arc bows out, as a fraction of the throw's length.
	var bulge: float

	func _init(start_in: Vector2, end_in: Vector2, start_scale_in := 1.0, start_angle_in := 0.0, end_angle_in := 0.0,
			bulge_in := 0.16) -> void:
		start = start_in
		end = end_in
		start_scale = start_scale_in
		start_angle = start_angle_in
		end_angle = end_angle_in
		bulge = bulge_in

	func position_at(t: float) -> Vector2:
		var d := end - start
		var length := d.length()
		if length < 1.0:
			return start.lerp(end, t)
		var control := start.lerp(end, 0.5) + Vector2(-d.y, d.x) / length * (length * bulge)
		var u := 1.0 - t
		return start * (u * u) + control * (2.0 * u * t) + end * (t * t)

	func angle_at(t: float) -> float:
		return start_angle + (end_angle - start_angle) * t

	func scale_at(t: float) -> float:
		return start_scale + (1.0 - start_scale) * t + 0.12 * sin(PI * t)


## One card on the felt: its throw, its rest, and its part in the gather and
## sweep. Rendered by setting its node's transform; the card is drawn once.
class _Thrown:
	extends RefCounted

	const GATHER_SHARE := float(Motion.GATHER_MS) / (Motion.GATHER_MS + Motion.SWEEP_MS)

	var card: String
	var slot: int
	var seat := -1
	var node: CardView
	var ring: _Ring
	var path: ThrowPath
	## Arrive face down and turn over in mid-air (opponents' cards).
	var flip := false
	var entrance := 0.0
	var collect := 0.0
	var confirmed := true
	var age := 0.0
	var is_winner := false
	var gather := Vector2.ZERO
	var gather_angle := 0.0
	var collect_to := Vector2.ZERO

	func _init(card_in: String, slot_in: int, node_in: CardView) -> void:
		card = card_in
		slot = slot_in
		node = node_in
		ring = _Ring.new()
		node.add_child(ring)

	func render(w: float) -> void:
		var h := w * CardView.FACE_ASPECT
		var center: Vector2
		var angle: float
		var scale: float
		var squash := 1.0
		var alpha := 1.0
		ring.visible = false
		if entrance < 1.0:
			var t := Motion.ease_out_cubic(entrance)
			center = path.position_at(t)
			angle = path.angle_at(t)
			scale = path.scale_at(t)
			if flip:
				# First half: the back turning edge-on; second half: the face
				# turning in from edge-on. Reads as one continuous flip.
				var back_showing := entrance < 0.5
				var turn := entrance / 0.5 if back_showing else 1.0 - (entrance - 0.5) / 0.5
				squash = cos(turn * PI / 2.0)
				if node.face_up == back_showing:
					node.face_up = not back_showing
					node.queue_redraw()
		else:
			if not node.face_up:
				node.face_up = true
				node.queue_redraw()
			var g := Motion.emphasized(clampf(collect / GATHER_SHARE, 0.0, 1.0))
			var s := Motion.ease_in_cubic(clampf((collect - GATHER_SHARE) / (1.0 - GATHER_SHARE), 0.0, 1.0))
			center = path.end.lerp(gather, g).lerp(collect_to, s) if collect > 0.0 else path.end
			angle = path.end_angle + (gather_angle - path.end_angle) * g if collect > 0.0 else path.end_angle
			var pulse := 0.12 * sin(PI * g) if is_winner else 0.0
			scale = (1.0 + pulse) * (1.0 - 0.5 * s)
			alpha = 1.0 - clampf((s - 0.35) / 0.65, 0.0, 1.0)
			if is_winner and collect > 0.0 and g < 1.0:
				# A ring bursting off the winning card as the others gather onto it.
				ring.visible = true
				ring.progress = g
				ring.card_width = w
				ring.queue_redraw()
		node.size = Vector2(w, h)
		node.pivot_offset = node.size / 2.0
		node.position = center - node.size / 2.0
		node.rotation = angle
		node.scale = Vector2(scale * squash, scale)
		node.modulate.a = alpha


class _Ring:
	extends Control

	var progress := 0.0
	var card_width := 44.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false

	func _draw() -> void:
		var parent := get_parent() as Control
		var c := parent.size / 2.0 if parent != null else Vector2.ZERO
		var d := card_width * (1.1 + 0.9 * progress)
		Draw.circle_border(self, c, d / 2.0, Color(Tokens.TURN_GLOW, 0.7 * (1.0 - progress)), 2.5)
