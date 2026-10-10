class_name SeatView
extends Control

## One player's place at the table: name chip, avatar and won/bid chip — in a
## row at the top and bottom, a column at the sides. Opponents' avatars wear
## their face-down hand as a small fan pointing at the table centre.
##
## Also where the table talks about a player: a ring that pings when their
## turn comes, a speech bubble when they bid, and a "+1" that floats off their
## score when they take a trick.

enum Slot { BOTTOM, LEFT, TOP, RIGHT }

## How long a "Bid N" bubble stays up.
const BUBBLE_TIME := 1.5

var slot: int
var avatar: SeatAvatar
var _body: BoxContainer
var _name_chip: NameChip
var _bid_chip: BidChip
var _bubble: BidBubble
var _bid := -1
var _bubble_timer: SceneTreeTimer


## Where [param seat] sits on screen for [param viewer]: always bottom for the
## viewer, then clockwise.
static func slot_for(seat: int, viewer: int) -> int:
	return (seat - maxi(viewer, 0) + 4) % 4


## The side seats stack their plates above and below the avatar; the top and
## bottom run across.
func _init(slot_in: int) -> void:
	slot = slot_in
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body = BoxContainer.new()
	_body.vertical = slot == Slot.LEFT or slot == Slot.RIGHT
	_body.alignment = BoxContainer.ALIGNMENT_CENTER
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_constant_override("separation", int(UI.sc(5, 3) if _body.vertical else UI.sc(6, 4)))
	var is_you := slot == Slot.BOTTOM
	_name_chip = NameChip.new()
	# The side seats share the table's width with the played cards between
	# them, so their names are held to the narrower width at either angle.
	_name_chip.max_name_width = 64.0 if _body.vertical or not UI.portrait else 84.0
	avatar = SeatAvatar.new(UI.sc(44, 42) if is_you else UI.sc(44, 40), slot)
	_bid_chip = BidChip.new()
	for c in [_name_chip, avatar, _bid_chip]:
		c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_body.add_child(c)
	add_child(_body)
	_body.minimum_size_changed.connect(update_minimum_size)
	resized.connect(func(): _body.size = size; _place_bubble())
	_bubble = BidBubble.new()
	add_child(_bubble)


func _get_minimum_size() -> Vector2:
	return _body.get_combined_minimum_size()


## The most room this seat can need — as if it held the dealer's badge and the
## widest score — so the table can keep it free without shuffling as the deal
## moves round and scores grow. Laid out like the seat itself.
func reserved_size() -> Vector2:
	var parts: Array[Vector2] = [_name_chip.reserved_size(), avatar.get_combined_minimum_size(), BidChip.widest()]
	var sep := float(_body.get_theme_constant("separation"))
	var out := Vector2.ZERO
	for p in parts:
		if _body.vertical:
			out = Vector2(maxf(out.x, p.x), out.y + p.y)
		else:
			out = Vector2(out.x + p.x, maxf(out.y, p.y))
	return out + (Vector2(0, sep * 2.0) if _body.vertical else Vector2(sep * 2.0, 0))


## How far this seat reaches from its avatar's centre toward the middle of the
## table: its face-down fan, or for the player's own plate, the avatar.
func fan_reach() -> float:
	return avatar.fan_reach()


## Refreshes everything from the current view.
func update(player: Dictionary, bid: int, tricks: int, is_turn: bool, is_dealer: bool, is_host: bool,
		deadline_ms: int, hand_count: int) -> void:
	_name_chip.set_state(str(player.get("name", "")), is_dealer, is_host, is_turn)
	_bid_chip.set_state(bid, tricks)
	avatar.update(player, is_turn, deadline_ms, hand_count if slot != Slot.BOTTOM else 0)
	if _bid < 0 and bid >= 0 and slot != Slot.BOTTOM:
		_bubble.show_bid(bid)
		_place_bubble()
		var timer := get_tree().create_timer(BUBBLE_TIME) if is_inside_tree() else null
		_bubble_timer = timer
		if timer != null:
			timer.timeout.connect(func():
				if _bubble_timer == timer:
					_bubble.show_bid(-1))
	elif bid < 0 and _bubble.bid >= 0:
		_bubble_timer = null
		_bubble.show_bid(-1)
	_bid = bid


## Speech bubbles open toward the middle of the table, where there is room
## and where the eye already is.
func _place_bubble() -> void:
	var b := _bubble.get_combined_minimum_size()
	_bubble.size = b
	var d := avatar.diameter
	match slot:
		Slot.TOP:
			_bubble.position = Vector2((size.x - b.x) / 2.0, d + 40)
		Slot.LEFT:
			_bubble.position = Vector2(d + 34, (size.y - b.y) / 2.0)
		Slot.RIGHT:
			_bubble.position = Vector2(size.x - d - 34 - b.x, (size.y - b.y) / 2.0)
		_:
			_bubble.position = Vector2((size.x - b.x) / 2.0, size.y - d - 8 - b.y)
	_bubble.pivot_offset = b / 2.0


## The avatar's centre in this seat's parent's coordinates.
func avatar_center_in(node: Control) -> Vector2:
	return avatar.get_global_rect().get_center() - node.get_global_rect().position


## Text centred on [param center], laid out like the design's 1.25-line text.
static func centered_text(ci: CanvasItem, text: String, center: Vector2, font_size: float, weight: String,
		color: Color) -> void:
	var font := Tokens.font(weight)
	var fs := maxi(1, int(round(font_size)))
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	ci.draw_string(font, Vector2(center.x - tw / 2.0, center.y + fs * 1.25 * (Tokens.SANS_BASELINE - 0.5)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


## Dark glass plate shared by the name and bid chips.
static func _chip(ci: CanvasItem, rect: Rect2, border: Color) -> void:
	var r := UI.sc(10, 8)
	Draw.box_shadow(ci, rect, r, Tokens.SHADOW_LOW)
	Draw.fill(ci, Draw.rounded_rect_points(rect, r), Color("#061410E0"))
	Draw.stroke_rounded_rect(ci, rect, r, border, 1.0)


class NameChip:
	extends Control

	var name_text := ""
	## The widest a name may run before it is cut short.
	var max_name_width := 84.0
	var dealer := false
	var host := false
	## Their turn — the plate's border warms to match the ring.
	var highlighted := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_state(n: String, is_dealer: bool, is_host: bool, is_turn: bool) -> void:
		if n == name_text and is_dealer == dealer and is_host == host and is_turn == highlighted:
			return
		name_text = n
		dealer = is_dealer
		host = is_host
		highlighted = is_turn
		update_minimum_size()
		queue_redraw()

	func _font_size() -> int:
		return int(round(UI.sc(11.5, 10)))

	func _name_width() -> float:
		var w := Tokens.font("semibold").get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size()).x
		return minf(w, max_name_width)

	func _get_minimum_size() -> Vector2:
		return _size_with(dealer)

	## The size with the dealer's badge, wherever the deal is now.
	func reserved_size() -> Vector2:
		return _size_with(true)

	func _size_with(with_dealer: bool) -> Vector2:
		var badge := UI.sc(14, 11)
		var gap := UI.sc(4, 3)
		var w := _name_width() + (badge + gap if host else 0.0) + (badge + gap if with_dealer else 0.0)
		var h := maxf(_font_size() * 1.25, badge if host or with_dealer else 0.0)
		return Vector2(w + UI.sc(8, 6) * 2.0, h + UI.sc(4, 3) * 2.0)

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		SeatView._chip(self, rect, Color(Tokens.TURN_GLOW, 0.7) if highlighted else Tokens.HAIRLINE_STRONG)
		var badge := UI.sc(14, 11)
		var gap := UI.sc(4, 3)
		var x := UI.sc(8, 6)
		var cy := size.y / 2.0
		if host:
			var r := Rect2(x, cy - badge / 2.0, badge, badge)
			Draw.fill(self, Draw.rounded_rect_points(r, UI.sc(4, 3)), Color(Tokens.GOLD, 0.18))
			Draw.icon(self, "crown", Rect2(r.get_center() - Vector2.ONE * badge * 0.36, Vector2.ONE * badge * 0.72),
					Tokens.GOLD)
			x += badge + gap
		var font := Tokens.font("semibold")
		var fs := _font_size()
		var text := name_text
		var max_w := _name_width()
		if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w + 0.5:
			while text.length() > 1 and font.get_string_size(text + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
				text = text.left(text.length() - 1)
			text += "…"
		draw_string(font, Vector2(x, cy + fs * 1.25 * (Tokens.SANS_BASELINE - 0.5)), text, HORIZONTAL_ALIGNMENT_LEFT,
				-1, fs, Tokens.GOLD_LIGHT if highlighted else Tokens.TEXT_PRIMARY)
		x += max_w + gap
		if dealer:
			var r := Rect2(x, cy - badge / 2.0, badge, badge)
			Draw.rounded_rect(self, r, badge / 2.0, Tokens.GOLD_BUTTON, true, Color.TRANSPARENT, 0,
					Tokens.GOLD_BUTTON_STOPS)
			SeatView.centered_text(self, "D", r.get_center(), badge * 0.6, "bold", Tokens.ON_GOLD)


## Tricks won against the bid, as "won/bid" with a thin progress bar under it.
## Turns green with a check once the bid is made, and floats a "+1" off itself
## whenever a trick is taken.
class BidChip:
	extends Control

	const POP_TIME := 0.8

	var bid := -1
	var won := 0
	var _progress := 0.0
	var _progress_from := 0.0
	var _progress_t := 1.0
	var _pop_t := 1.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(false)

	func set_state(bid_in: int, won_in: int) -> void:
		if bid_in == bid and won_in == won:
			return
		if won_in > won and bid_in == bid:
			_pop_t = 0.0
		var target := _target(bid_in, won_in)
		if target != _target(bid, won):
			_progress_from = _progress
			_progress_t = 0.0
		bid = bid_in
		won = won_in
		set_process(true)
		update_minimum_size()
		queue_redraw()

	static func _target(b: int, w: int) -> float:
		return 0.0 if b <= 0 else clampf(float(w) / b, 0.0, 1.0)

	func _process(delta: float) -> void:
		_pop_t = minf(_pop_t + delta / POP_TIME, 1.0)
		_progress_t = minf(_progress_t + delta / 0.32, 1.0)
		_progress = lerpf(_progress_from, _target(bid, won), Motion.emphasized(_progress_t))
		if _pop_t >= 1.0 and _progress_t >= 1.0:
			set_process(false)
		queue_redraw()

	func _made() -> bool:
		return bid >= 0 and won >= bid

	func _sizes() -> Array:
		return _sizes_for(bid, won)

	static func _sizes_for(b: int, w: int) -> Array:
		var big := int(round(UI.sc(13, 11)))
		var small := int(round(UI.sc(11, 9.5)))
		var main := "–" if b < 0 else str(w)
		var rest := "" if b < 0 else "/%d" % b
		var mw := Tokens.font("bold").get_string_size(main, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
		var rw := Tokens.font("semibold").get_string_size(rest, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x if rest != "" else 0.0
		var check := UI.sc(12, 10) + UI.sc(2, 1) if b >= 0 and w >= b else 0.0
		return [big, small, main, rest, mw, rw, check]

	func _get_minimum_size() -> Vector2:
		return _size_for(bid, won)

	## The size of the widest score there can be: a bid of 13, made.
	static func widest() -> Vector2:
		return _size_for(Rules.MAX_BID, Rules.MAX_BID)

	static func _size_for(b: int, won_in: int) -> Vector2:
		var s := _sizes_for(b, won_in)
		var row_w: float = s[4] + s[5] + s[6]
		var w := row_w
		var h: float = s[0] * 1.25
		if b >= 0:
			w = maxf(w, UI.sc(26, 20))
			h += UI.sc(3, 2) + UI.sc(3, 2.5)
		return Vector2(w + UI.sc(8, 6) * 2.0, h + UI.sc(4, 3) * 2.0)

	func _draw() -> void:
		var s := _sizes()
		var made := _made()
		var accent := Tokens.SUCCESS if made else Tokens.GOLD
		var bump := 0.18 * sin(PI * clampf(_pop_t * 2.5, 0.0, 1.0)) if _pop_t < 1.0 else 0.0
		draw_set_transform(size / 2.0 * (1.0 - (1.0 + bump)), 0.0, Vector2.ONE * (1.0 + bump))
		SeatView._chip(self, Rect2(Vector2.ZERO, size), Color(Tokens.SUCCESS, 0.6) if made else Tokens.HAIRLINE_STRONG)
		var pad_y := UI.sc(4, 3)
		var row_h: float = s[0] * 1.25
		var row_w: float = s[4] + s[5] + s[6]
		var x := (size.x - row_w) / 2.0
		var cy := pad_y + row_h / 2.0
		var baseline: float = cy + s[0] * 1.25 * (Tokens.SANS_BASELINE - 0.5)
		if made:
			var ic := UI.sc(12, 10)
			Draw.icon(self, "check", Rect2(x, cy - ic / 2.0, ic, ic), Tokens.SUCCESS)
			x += s[6]
		draw_string(Tokens.font("bold"), Vector2(x, baseline), s[2], HORIZONTAL_ALIGNMENT_LEFT, -1, s[0],
				Tokens.TEXT_MUTED if bid < 0 else accent)
		x += s[4]
		if s[3] != "":
			# The smaller "/bid" shares the larger figure's baseline.
			draw_string(Tokens.font("semibold"), Vector2(x, baseline), s[3], HORIZONTAL_ALIGNMENT_LEFT, -1, s[1],
					Color(Tokens.TEXT_PRIMARY, 0.6))
		if bid >= 0:
			var bw := UI.sc(26, 20)
			var bh := UI.sc(3, 2.5)
			var bar := Rect2((size.x - bw) / 2.0, pad_y + row_h + UI.sc(3, 2), bw, bh)
			Draw.fill(self, Draw.rounded_rect_points(bar, 2), Tokens.HAIRLINE_STRONG)
			if _progress > 0.01:
				Draw.fill(self, Draw.rounded_rect_points(Rect2(bar.position, Vector2(bw * _progress, bh)), 2), accent)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if _pop_t < 1.0:
			var font := Tokens.font("bold")
			var tw := font.get_string_size("+1", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			var top := -14.0 - 18.0 * Motion.enter(_pop_t)
			var alpha := clampf(1.0 - _pop_t, 0.0, 1.0)
			var pos := Vector2((size.x - tw) / 2.0, top + 14 * 1.25 * Tokens.SANS_BASELINE)
			draw_string_outline(font, pos, "+1", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color(0, 0, 0, 0.45 * alpha))
			draw_string(font, pos, "+1", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(Tokens.TURN_GLOW, alpha))


## "Bid 4" in a speech bubble, popping out of a seat for a moment when that
## player commits to their bid.
class BidBubble:
	extends Control

	var bid := -1
	var _shown := -1
	var _t := 1.0
	var _entering := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(false)
		visible = false

	func show_bid(b: int) -> void:
		bid = b
		if b >= 0:
			_shown = b
			_entering = true
			visible = true
		else:
			_entering = false
		_t = 0.0
		update_minimum_size()
		set_process(true)

	func _get_minimum_size() -> Vector2:
		var a := Tokens.font("semibold").get_string_size("Bid ", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var b := Tokens.font("bold").get_string_size(str(maxi(_shown, 0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		return Vector2(a + b + 22, 15 * 1.25 + 12)

	func _process(delta: float) -> void:
		_t = minf(_t + delta / 0.26, 1.0)
		var e := Motion.ease_out_back(_t) if _entering else 1.0 - Motion.ease_in(_t)
		modulate.a = clampf(e, 0.0, 1.0)
		scale = Vector2.ONE * maxf(e, 0.0)
		if _t >= 1.0:
			set_process(false)
			if not _entering:
				visible = false

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		Draw.box_shadow(self, rect, 12, Tokens.glow(Tokens.GOLD_DEEP, 0.8))
		Draw.rounded_rect(self, rect, 12, Tokens.GOLD_BUTTON, true, Color.TRANSPARENT, 0, Tokens.GOLD_BUTTON_STOPS)
		var baseline := 6 + 15 * 1.25 * Tokens.SANS_BASELINE
		var a := Tokens.font("semibold").get_string_size("Bid ", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(Tokens.font("semibold"), Vector2(11, baseline), "Bid ", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Tokens.ON_GOLD)
		draw_string(Tokens.font("bold"), Vector2(11 + a, baseline), str(_shown), HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
				Tokens.ON_GOLD)


class SeatAvatar:
	extends Control

	const PING_TIME := 0.75
	## How far out from the avatar's centre the face-down fan's cards sit, in
	## card heights.
	const FAN_OFFSET := 0.55

	var diameter: float
	var slot: int
	var player := {}
	var is_turn := false
	var hand_count := 0
	var clock: TurnClock
	var _turn_alpha := 0.0
	var _ping_t := 1.0
	var _tween: Tween

	func _init(d: float, slot_in: int) -> void:
		diameter = d
		slot = slot_in
		var ring := d + 10.0
		custom_minimum_size = Vector2(ring, ring)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clock = TurnClock.new()
		clock.audible = slot == SeatView.Slot.BOTTOM
		clock.size = Vector2(ring, ring)
		clock.custom_minimum_size = Vector2(ring, ring)
		add_child(clock)
		Settings.changed.connect(queue_redraw)
		set_process(false)

	func update(p: Dictionary, turn: bool, deadline_ms: int, count: int) -> void:
		var changed := p != player or count != hand_count or turn != is_turn
		player = p
		hand_count = count
		clock.deadline_ms = deadline_ms
		if turn != is_turn:
			is_turn = turn
			if turn:
				# The ring pings once as the turn arrives, then holds steady.
				_ping_t = 0.0
				set_process(true)
			if _tween != null:
				_tween.kill()
			_tween = create_tween()
			_tween.tween_method(_set_turn_alpha, _turn_alpha, 1.0 if turn else 0.0, 0.22)
		if changed:
			queue_redraw()

	func _set_turn_alpha(v: float) -> void:
		_turn_alpha = v
		queue_redraw()

	func _process(delta: float) -> void:
		_ping_t = minf(_ping_t + delta / PING_TIME, 1.0)
		if _ping_t >= 1.0:
			set_process(false)
		queue_redraw()

	func _draw() -> void:
		var ring := diameter + 10.0
		var c := Vector2(ring, ring) / 2.0
		var is_you := slot == SeatView.Slot.BOTTOM
		_draw_hand_fan()
		if _turn_alpha > 0.01:
			var a := _turn_alpha
			if _ping_t < 1.0:
				var t := Motion.enter(_ping_t)
				var pd := ring * (1.0 + 0.55 * t)
				Draw.circle_border(self, c, pd / 2.0, Color(Tokens.TURN_GLOW, 0.8 * (1.0 - t) * a), 2.0)
			var rr := Rect2(c - Vector2.ONE * ring / 2.0, Vector2.ONE * ring)
			Draw.box_shadow(self, rr, ring / 2.0, [[Color(Tokens.TURN_GLOW, 0.45 * 1.1 * a), 16.0, Vector2.ZERO, 0.55]])
			Draw.circle_border(self, c, ring / 2.0, Color(Tokens.TURN_GLOW, a), 2.2)
		var rect := Rect2(c - Vector2(diameter, diameter) / 2.0, Vector2(diameter, diameter))
		Draw.box_shadow(self, rect, diameter / 2.0, Tokens.SHADOW_LOW)
		var stops: Array
		if is_you:
			stops = [Tokens.GOLD_LIGHT, Tokens.GOLD_MID, Tokens.GOLD_DEEP]
		else:
			var av: Array = Settings.palette()["avatar"]
			stops = [(av[0] as Color).lerp(Color.WHITE, 0.12), av[0], av[1]]
		Draw.fill_linear(self, Draw.ellipse_points(c, Vector2.ONE * diameter / 2.0, 48), rect.position, rect.end, stops)
		Draw.circle_border(self, c, diameter / 2.0,
				Color(Tokens.GOLD_LIGHT, 0.95) if is_you else Color(Tokens.GOLD_BORDER, 0.9 if is_turn else 0.35),
				2.0 if is_you else 1.6)
		SeatView.centered_text(self, GameView.initial(str(player.get("name", ""))), c, diameter * 0.42, "bold",
				Tokens.ON_GOLD if is_you else Tokens.TEXT_ON_DARK)
		var connected: bool = player.get("connected", true)
		var bot := GameView.is_bot(player)
		# Offline: veil the avatar so an absent player is obvious even in
		# peripheral vision.
		if not connected:
			Draw.disc(self, c, diameter / 2.0, Color("#000000B3"))
			Draw.icon(self, "wifi_off", Rect2(c - Vector2.ONE * diameter * 0.19, Vector2.ONE * diameter * 0.38),
					Tokens.TEXT_MUTED)
		var badge := diameter * 0.36
		# A bot is driving this seat — the occupant is a bot outright, or their
		# connection dropped and the table stopped waiting for them.
		if bot or not connected:
			_bot_badge(Vector2(badge / 2.0, badge / 2.0), badge)
		# Autoplay: still here and connected, but the table stopped waiting. One
		# tap away from being theirs again, so a different corner.
		if player.get("autoplay", false) and connected:
			_bot_badge(Vector2(ring - badge / 2.0, badge / 2.0), badge)
		# Presence lamp, for human seats only.
		if not bot:
			var dot := diameter * 0.28
			var dc := Vector2(ring, ring) - Vector2(dot, dot) / 2.0
			var dr := Rect2(dc - Vector2.ONE * dot / 2.0, Vector2.ONE * dot)
			if connected:
				Draw.box_shadow(self, dr, dot / 2.0, [[Color(Tokens.SUCCESS, 0.55), dot * 0.5, Vector2.ZERO]])
			Draw.disc(self, dc, dot / 2.0, Tokens.SUCCESS if connected else Tokens.TEXT_MUTED)
			Draw.circle_border(self, dc, dot / 2.0, Color("#0A1207E6"), dot * 0.18)

	## The size of one card in the face-down fan.
	static func _fan_card() -> Vector2:
		var cw := UI.sc(24, 20)
		return Vector2(cw, cw * CardView.FACE_ASPECT)

	## How far the face-down fan reaches from the avatar's centre toward the
	## table, at most: with a full hand, where it spreads widest.
	func fan_reach() -> float:
		var ring := diameter / 2.0 + 5.0
		if slot == SeatView.Slot.BOTTOM:
			return ring
		var fan := fan_rect(Rules.TRICKS_PER_HAND)
		var c := Vector2.ONE * ring
		match slot:
			SeatView.Slot.TOP: return maxf(fan.end.y - c.y, ring)
			SeatView.Slot.LEFT: return maxf(fan.end.x - c.x, ring)
		return maxf(c.x - fan.position.x, ring)

	func _bot_badge(center: Vector2, size: float) -> void:
		Draw.disc(self, center, size / 2.0, Color("#0A1207F0"))
		Draw.circle_border(self, center, size / 2.0, Tokens.GOLD_MID, size * 0.09)
		Draw.icon(self, "robot", Rect2(center - Vector2.ONE * size * 0.29, Vector2.ONE * size * 0.58), Tokens.GOLD_MID)

	## A face-down fan of the opponent's remaining cards in front of the avatar
	## (toward the table centre), pivoting on the avatar's centre.
	func _draw_hand_fan() -> void:
		var placed := _fan_transforms(hand_count)
		if placed.is_empty():
			return
		var card := _fan_card()
		var rect := Rect2(-card / 2.0, card)
		# The cards behind in one draw call; then the front one, the only one
		# with a shadow, over it.
		var art := Draw.Batch.new()
		for i in placed.size() - 1:
			art.transform = placed[i]
			CardView.back_art(art, rect)
		art.flush(self)
		draw_set_transform_matrix(placed[-1])
		CardView.back_shadow(self, rect)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		art.transform = placed[-1]
		CardView.back_art(art, rect)
		art.flush(self)

	## Where each card of a face-down fan of [param count] is drawn: its centre
	## and turn.
	func _fan_transforms(count: int) -> Array[Transform2D]:
		var out: Array[Transform2D] = []
		if count <= 0 or slot == SeatView.Slot.BOTTOM:
			return out
		var c := Vector2.ONE * (diameter + 10.0) / 2.0
		var sweep := (count - 1) * 0.13
		var dir0: Vector2
		var base: float
		match slot:
			SeatView.Slot.TOP: dir0 = Vector2(0, 1); base = 0.0
			SeatView.Slot.LEFT: dir0 = Vector2(1, 0); base = -PI / 2
			_: dir0 = Vector2(-1, 0); base = PI / 2
		for i in count:
			var t := 0.0 if count == 1 else float(i) / (count - 1) - 0.5
			var theta := t * sweep
			out.append(Transform2D(base + theta, c + dir0.rotated(theta) * (_fan_card().y * FAN_OFFSET)))
		return out

	## The face-down fan's bounds in this avatar's own coordinates — as it is
	## now, or holding [param count] cards — or an empty rect when there is none.
	func fan_rect(count := -1) -> Rect2:
		var half := _fan_card() / 2.0
		var corners := [-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]
		var points := PackedVector2Array()
		for xf in _fan_transforms(hand_count if count < 0 else count):
			for corner in corners:
				points.append(xf * corner)
		if points.is_empty():
			return Rect2()
		var out := Rect2(points[0], Vector2.ZERO)
		for p in points:
			out = out.expand(p)
		return out
