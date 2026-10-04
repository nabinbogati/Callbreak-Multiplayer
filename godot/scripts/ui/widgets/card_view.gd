class_name CardView
extends Control

## One playing card, face up or face down, drawn in vector at any size.
##
## Face: the current card style's paint, rank and suit in the corner, a gold
## edge for trumps. Back: the table theme's gradient with a gold inner frame
## and, optionally, the spade emblem the hero fan uses. The pivot is kept at
## the centre so rotations and zooms turn about the middle of the card.

## Face proportions (54×80) and back proportions (72×100) from the design.
const FACE_ASPECT := 80.0 / 54.0
const BACK_ASPECT := 100.0 / 72.0

var card := ""
var face_up := true
var dimmed := false:
	set(v):
		dimmed = v
		queue_redraw()
var highlighted := false:
	set(v):
		highlighted = v
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
	var h := width * (FACE_ASPECT if face_up else BACK_ASPECT)
	custom_minimum_size = Vector2(width, h)
	size = custom_minimum_size
	pivot_offset = size / 2.0
	queue_redraw()


func card_height() -> float:
	return card_width * (FACE_ASPECT if face_up else BACK_ASPECT)


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(card_width, card_height()))
	if face_up:
		CardView.paint_face(self, rect, card, dimmed, highlighted, shadow)
	else:
		CardView.paint_back(self, rect, spade_emblem, shadow)


static func paint_face(ci: CanvasItem, rect: Rect2, card_id: String, is_dimmed := false,
		is_highlighted := false, with_shadow := true) -> void:
	var w := rect.size.x
	var palette := Settings.card_face()
	var radius := w * 7.0 / 54.0
	var alpha := 0.45 if is_dimmed else 1.0
	if is_highlighted:
		Draw.shadow(ci, rect, radius, Vector2(0, w * 8.0 / 54.0), w * 16.0 / 54.0,
				Color(Tokens.GOLD_DEEP, 0.45 * alpha))
	elif with_shadow:
		Draw.shadow(ci, rect, radius, Vector2(0, w * 6.0 / 54.0), w * 10.0 / 54.0, Color(0, 0, 0, 0.3 * alpha))
	var trump := Cards.is_trump(card_id)
	var edge: Color = palette["trump_edge"] if trump else palette["edge"]
	var face_color: Color = palette["face"]
	face_color.a *= alpha
	edge.a *= alpha
	Draw.rounded_rect(ci, rect, radius, [face_color], true, edge, w * (1.5 if trump else 1.0) / 54.0)

	var ink: Color = palette["red"] if Cards.is_red(card_id) else palette["ink"]
	ink.a *= alpha
	var pad := w * 6.0 / 54.0
	var font := Tokens.font("bold")
	var rank_size := int(round(w * 14.0 / 54.0))
	var ascent := font.get_ascent(rank_size)
	var text := Cards.label(card_id)
	var origin := rect.position
	ci.draw_string(font, origin + Vector2(pad - (w / 54.0 if text == "10" else 0.0), pad + ascent * 0.92), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, rank_size, ink)
	var suit_size := w * 15.0 / 54.0
	Draw.suit(ci, Cards.suit(card_id),
			origin + Vector2(pad + suit_size * 0.45, pad + ascent + w * 4.0 / 54.0 + suit_size * 0.5), suit_size, ink)


static func paint_back(ci: CanvasItem, rect: Rect2, emblem := false, with_shadow := true) -> void:
	var w := rect.size.x
	var palette := Settings.palette()
	var radius := w * 8.0 / 72.0
	if with_shadow:
		Draw.shadow(ci, rect, radius, Vector2(0, w * 0.07), w * 0.14, Color(0, 0, 0, 0.32))
	Draw.rounded_rect(ci, rect, radius, palette["card_back"], true, Color(Tokens.GOLD_BORDER, 0.7), w * 1.5 / 72.0)
	var inner := rect.grow(-w * 8.0 / 72.0)
	var frame := Draw.rounded_rect_points(inner, radius * 0.5)
	frame.append(frame[0])
	ci.draw_polyline(frame, Color(Tokens.GOLD_BORDER, 0.4), 1.0, true)
	if emblem:
		var c := rect.get_center()
		var r := w * 17.0 / 72.0
		for i in 3:
			ci.draw_circle(c, r * (1.0 + 0.18 * i), Color(Tokens.GOLD, 0.12 - 0.035 * i), true, -1.0, true)
		Draw.suit(ci, Cards.Suit.SPADES, c + Vector2(1, 1.5), w * 26.0 / 72.0, Color(Tokens.GOLD_DEEP, 0.8))
		Draw.suit(ci, Cards.Suit.SPADES, c, w * 24.0 / 72.0, Color(0.05, 0.04, 0.02))
