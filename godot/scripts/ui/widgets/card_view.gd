class_name CardView
extends Control

## One playing card, face up or face down, drawn in vector at any size. Every
## measurement is derived from the width, so the same painter draws the hand
## card, the card on the felt and the settings preview.
##
## Face: laid out like a real deck — rank over suit in the top-left corner (the
## only part a tightly overlapped fan shows), mirrored in the bottom-right, and
## a large centre pip so a card lying on the felt reads from across the table.
## Court cards carry their letter in the display face instead of a pip; trumps
## catch a little gold light in the corner. Back: a gold-framed lattice in the
## table's colourway with a spade medallion, the same proportions as the face,
## so a dealt card turns over into the hand without changing shape. The pivot
## is kept at the centre so rotations and zooms turn about the middle.

const FACE_ASPECT := 80.0 / 54.0
const BACK_ASPECT := FACE_ASPECT

## Illegal to play right now: a veil over an opaque card, so overlapped fan
## cards never show through one another.
const VEIL := Color("#0A14108A")

var card := ""
var face_up := true
var dimmed := false:
	set(v):
		if v != dimmed:
			dimmed = v
			queue_redraw()
## Lit with a warm halo — a playable card on your turn, or the card currently
## winning the trick.
var highlighted := false:
	set(v):
		if v != highlighted:
			highlighted = v
			queue_redraw()
## 0 resting … 1 held high (being previewed or dragged); deepens the shadow so
## a lifted card visibly leaves the fan.
var elevation := 0.0:
	set(v):
		if v != elevation:
			elevation = v
			queue_redraw()
var shadow := true
var spade_emblem := false
var card_width := 54.0


static func face(card_id: String, width: float) -> CardView:
	var c := CardView.new()
	c.card = card_id
	c.face_up = true
	c.set_card_width(width)
	return c


static func back(width: float, emblem := false) -> CardView:
	var c := CardView.new()
	c.face_up = false
	c.spade_emblem = emblem
	c.set_card_width(width)
	return c


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Settings.changed.connect(queue_redraw)


func set_card_width(width: float) -> void:
	card_width = width
	custom_minimum_size = Vector2(width, width * FACE_ASPECT)
	size = custom_minimum_size
	pivot_offset = size / 2.0
	queue_redraw()


func card_height() -> float:
	return card_width * FACE_ASPECT


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(card_width, card_height()))
	if face_up:
		CardView.paint_face(self, rect, card, dimmed, highlighted, shadow, elevation)
	else:
		CardView.paint_back(self, rect, spade_emblem, shadow)


# ------------------------------------------------------------------- face

## A card's face: its shadow, then all of its shapes in one draw call, then its
## lettering.
static func paint_face(ci: CanvasItem, rect: Rect2, card_id: String, is_dimmed := false,
		is_highlighted := false, with_shadow := true, lift := 0.0) -> void:
	var w := rect.size.x
	var palette := Settings.card_face()
	var face_color: Color = palette["face"]
	var radius := w * 0.11
	var e := clampf(lift, 0.0, 1.0)
	var shadows := []
	if is_highlighted:
		shadows.append([Color(Tokens.TURN_GLOW, 0.75), w * 0.32, Vector2.ZERO, w * 0.03])
	if with_shadow or is_highlighted:
		shadows.append([Color(0, 0, 0, 0.32 + 0.14 * e), w * (0.16 + 0.22 * e), Vector2(0, w * (0.08 + 0.16 * e))])
	Draw.box_shadow(ci, rect, radius, shadows)

	var art := Draw.Batch.new()
	var trump := Cards.is_trump(card_id)
	var pts := Draw.rounded_rect_points(rect, radius, 8)
	art.fill_linear(pts, rect.position, Vector2(rect.position.x, rect.end.y),
			[face_color.lerp(Color.WHITE, 0.06), face_color, face_color.lerp(Color.BLACK, 0.07)], [0.0, 0.55, 1.0])
	if trump:
		# Spades are findable in the fan even before the suit is read.
		art.fill_linear(pts, Vector2(rect.end.x, rect.position.y), rect.get_center(),
				[Color(Tokens.GOLD_MID, 0.32), Color(Tokens.GOLD_MID, 0.0)], [], false)
	art.stroke_rounded_rect(rect, radius, palette["trump_edge"] if trump else palette["edge"],
			w * (0.032 if trump else 0.02))

	var ink: Color = palette["red"] if Cards.is_red(card_id) else palette["ink"]
	var pad := w * 0.075
	var top_left := rect.position + Vector2(pad, pad * 0.55)
	# The mirrored index, turned about its own box.
	var turned := Transform2D(PI, rect.end - Vector2(pad, pad * 0.55))
	_index_suit(art, card_id, ink, w, top_left)
	art.transform = turned
	_index_suit(art, card_id, ink, w, Vector2.ZERO)
	art.transform = Transform2D.IDENTITY
	_center_suit(art, card_id, ink, w, rect.get_center())
	art.flush(ci)

	_index_rank(ci, card_id, ink, w, top_left)
	ci.draw_set_transform_matrix(turned)
	_index_rank(ci, card_id, ink, w, Vector2.ZERO)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_center_letter(ci, card_id, ink, w, rect.get_center())
	if is_dimmed:
		art.fill(pts, VEIL)
		art.flush(ci)


## Width and height of the corner index (rank over suit).
static func _index_size(card_id: String, w: float) -> Vector2:
	var text := Cards.label(card_id)
	var fs := _rank_font_size(text, w)
	var tw := _rank_width(text, w, fs)
	var glyph := w * 0.17
	return Vector2(maxf(tw, glyph * Draw.suit_aspect(Cards.suit(card_id))), fs + w * 0.025 + glyph)


static func _rank_font_size(text: String, w: float) -> int:
	return maxi(1, int(round(w * (0.25 if text.length() > 1 else 0.28))))


## "10" is the one two-glyph rank; it is pulled together so it still fits the
## sliver of card a full fan leaves visible.
static func _rank_spacing(text: String, w: float) -> float:
	return -w * 0.025 if text.length() > 1 else 0.0


static func _rank_width(text: String, w: float, fs: int) -> float:
	var font := Tokens.font("bold")
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + _rank_spacing(text, w) * text.length()


## The rank of the corner index — rank over suit, the way a real index reads —
## with the index's top-left at [param origin] (or, under a half-turn transform,
## its bottom-right).
static func _index_rank(ci: CanvasItem, card_id: String, ink: Color, w: float, origin: Vector2) -> void:
	var text := Cards.label(card_id)
	var fs := _rank_font_size(text, w)
	var size := _index_size(card_id, w)
	var font := Tokens.font("bold")
	var tw := _rank_width(text, w, fs)
	# Flutter's `height: 1.0` line: the em box, baseline in proportion.
	var baseline := origin.y + fs * Tokens.SANS_BASELINE
	var x := origin.x + (size.x - tw) / 2.0
	var spacing := _rank_spacing(text, w)
	for ch in text:
		ci.draw_string(font, Vector2(x, baseline), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
		x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + spacing


## The suit under the rank of the corner index at [param origin].
static func _index_suit(art: Draw.Batch, card_id: String, ink: Color, w: float, origin: Vector2) -> void:
	var fs := _rank_font_size(Cards.label(card_id), w)
	var size := _index_size(card_id, w)
	var glyph := w * 0.17
	art.suit(Cards.suit(card_id), Vector2(origin.x + size.x / 2.0, origin.y + fs + w * 0.025 + glyph / 2.0), glyph, ink)


## The big centre mark: a pip for number cards, an oversized pip for the ace,
## the letter (in the display face) for court cards, with a small suit under it.
static func _center_suit(art: Draw.Batch, card_id: String, ink: Color, w: float, center: Vector2) -> void:
	var rank := Cards.rank(card_id)
	var suit := Cards.suit(card_id)
	if _is_court(rank):
		var c := _court_layout(w, center)
		art.suit(suit, Vector2(center.x, c.y + c.x + w * 0.16 / 2.0), w * 0.16, ink)
		return
	art.suit(suit, center, w * (0.56 if rank == 14 else 0.4), ink)


## A court card's letter, above the small suit [method _center_suit] draws.
static func _center_letter(ci: CanvasItem, card_id: String, ink: Color, w: float, center: Vector2) -> void:
	if not _is_court(Cards.rank(card_id)):
		return
	var fs := maxi(1, int(round(w * 0.42)))
	var c := _court_layout(w, center)
	var font := Tokens.font("display")
	var text := Cards.label(card_id)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	ci.draw_string(font, Vector2(center.x - tw / 2.0, c.y + c.x * Tokens.DISPLAY_BASELINE), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


static func _is_court(rank: int) -> bool:
	return rank >= 11 and rank <= 13


## A court card's letter line height and top: (line, top).
static func _court_layout(w: float, center: Vector2) -> Vector2:
	var fs := maxi(1, int(round(w * 0.42)))
	var line := fs * 1.05
	return Vector2(line, center.y - (line + w * 0.16) / 2.0)


# ------------------------------------------------------------------- back

static func paint_back(ci: CanvasItem, rect: Rect2, emblem := false, with_shadow := true) -> void:
	if with_shadow:
		back_shadow(ci, rect)
	var art := Draw.Batch.new()
	back_art(art, rect, emblem)
	art.flush(ci)


## The shadow under a card back.
static func back_shadow(ci: CanvasItem, rect: Rect2) -> void:
	var w := rect.size.x
	Draw.box_shadow(ci, rect, w * 0.11, [[Color("#00000066"), w * 0.18, Vector2(0, w * 0.08)]])


## A card back's artwork, gathered into [param art] — so a fan or a deck of
## backs, each placed with [member Draw.Batch.transform], costs one draw call.
static func back_art(art: Draw.Batch, rect: Rect2, emblem := false) -> void:
	var w := rect.size.x
	var palette := Settings.palette()
	var radius := w * 0.11
	var pts := Draw.rounded_rect_points(rect, radius, 8)
	art.fill_linear(pts, rect.position, rect.end, palette["card_back"])
	art.stroke_rounded_rect(rect, radius, Color(Tokens.GOLD_BORDER, 0.75), clampf(w * 0.03, 0.8, 3.0))

	var inner := rect.grow(-w * 0.085)
	var fine := w < 34.0
	var gold := Tokens.GOLD_BORDER
	# Lattice. Small cards (the opponents' face-down fans) skip it: at that size
	# it is noise.
	if not fine:
		_lattice(art, inner, Color(gold, 0.2))
	art.stroke(Draw.rounded_rect_points(inner, radius * 0.6, 8), true, Color(gold, 0.45), 0.7 if fine else 1.0)

	if not emblem and fine:
		return
	var c := inner.get_center()
	var iw := inner.size.x
	var r := iw * (0.36 if emblem else 0.3)
	# A diamond medallion behind the spade.
	var medallion := PackedVector2Array([c + Vector2(0, -r * 1.25), c + Vector2(r, 0), c + Vector2(0, r * 1.25),
			c + Vector2(-r, 0)])
	art.fill(medallion, Color("#00000099"))
	art.stroke(medallion, true, Color(gold, 0.8), 1.4 if emblem else 1.0)

	var glyph := iw * (0.46 if emblem else 0.34)
	if emblem:
		# A soft glow behind the hero's spade.
		for i in 4:
			var grow := 1.0 + 0.07 * (i + 1)
			art.suit(Cards.Suit.SPADES, c, glyph * grow, Color(Tokens.GOLD, 0.7 / 6.0))
	suit_gradient(art, Cards.Suit.SPADES, c, glyph, Tokens.GOLD_TEXT)


## A suit glyph filled with a vertical gradient through [param stops].
static func suit_gradient(art: Draw.Batch, suit_value: int, center: Vector2, size: float, stops: Array) -> void:
	var box := Vector2(size * Draw.suit_aspect(suit_value), size)
	var origin := center - box / 2.0
	for poly in Draw.suit_polygons(suit_value):
		var pts := PackedVector2Array()
		pts.resize(poly.size())
		for i in poly.size():
			pts[i] = origin + poly[i] * box
		art.fill_linear(pts, origin, origin + Vector2(0, size), stops)


## Both diagonals of the lattice, each segment cut to [param r].
static func _lattice(art: Draw.Batch, r: Rect2, color: Color) -> void:
	var w := r.size.x
	var h := r.size.y
	var step := w * 0.2
	var lines := PackedVector2Array()
	var d := -h
	while d < w:
		# y = x - d (falling to the right) and y = d + h - x (rising), both kept
		# to 0 <= x <= w; the x-range is where each stays within 0..h.
		var x0 := maxf(0.0, d)
		var x1 := minf(w, d + h)
		if x1 > x0:
			lines.append(r.position + Vector2(x0, x0 - d))
			lines.append(r.position + Vector2(x1, x1 - d))
			lines.append(r.position + Vector2(x0, d + h - x0))
			lines.append(r.position + Vector2(x1, d + h - x1))
		d += step
	for i in range(0, lines.size(), 2):
		art.stroke(PackedVector2Array([lines[i], lines[i + 1]]), false, color, 0.8)
