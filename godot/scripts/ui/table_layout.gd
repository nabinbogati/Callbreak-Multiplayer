class_name TableLayout
extends RefCounted

## Where everything at the table goes on one screen, and how large it is drawn.
##
## The table is laid out in table units — the design's own sizes, so a card or
## an avatar is always the size the design draws it — on a frame as large as
## its content needs, and then the whole frame is scaled to fill the screen.
## Every device sees the same table, larger or smaller: the seats, the hand
## and the played cards keep their places relative to each other and to the
## screen's edges, and a gap the layout keeps open at one size stays open at
## every size.
##
## The frame is never smaller than [constant PORTRAIT_REF] (or
## [constant LANDSCAPE_REF] on its side): a phone that size shows the table at
## scale 1, a larger screen scales it up, and a screen too cramped for the
## content (long names, a nearly square window) scales it down until it fits.
##
## The rules, in table units: the top seat sits on the felt's top rim and the
## side seats on its left and right rims, level with its centre; the played
## cards gather around that centre, clear of every seat's face-down fan; the
## player's own plate runs along the bottom edge under the hand. Nothing that
## stays on screen through a trick touches anything else.

## Space kept between things that must not touch.
const GAP := 6.0
## Between the screen's sides and the side seats.
const EDGE := 4.0
## The smallest frame, standing up and lying down. A screen this size (in
## design pixels) draws the table at scale 1.
const PORTRAIT_REF := Vector2(390, 700)
const LANDSCAPE_REF := Vector2(700, 390)
## How much of the player's own plate the resting hand reaches down over, as a
## share of the plate's height.
const PLATE_OVERLAP := 0.3
## The felt's long axis over its short one, standing up and lying down: a
## screen of another shape leaves room round the felt rather than squashing
## it, though never at the cost of a gap the layout keeps.
const PORTRAIT_ASPECT := Vector2(1.15, 1.62)
const LANDSCAPE_ASPECT := Vector2(1.6, 2.0)

# ---------------------------------------------------- what the table holds
# All in table units; set before [method solve].

var portrait := true
## The HUD row's minimum size, and the widths of its left and right groups.
var hud_size := Vector2.ZERO
var hud_left := 0.0
var hud_right := 0.0
## Seat sizes as [method SeatView.reserved_size] gives them; [member side_seat]
## is the larger of the two side seats.
var top_seat := Vector2.ZERO
var side_seat := Vector2.ZERO
var plate := Vector2.ZERO
## How far the face-down fans reach toward the centre from their avatars.
var top_reach := 0.0
var side_reach := 0.0
## The hand's card size and the fan's full height (cards, lift and arc).
var hand_card := Vector2.ZERO
var fan_height := 0.0
## How wide the played cards are.
var trick_width := 0.0
## The largest hint pill.
var hint_size := Vector2.ZERO

# ------------------------------------------------------------- the answer

## Table units to design pixels.
var scale := 1.0
## The table's size in table units: the screen's size over [member scale].
var frame := Vector2.ZERO
var hud := Rect2()
## The felt's centre, where the played cards gather.
var center := Vector2.ZERO
var felt := Rect2()
## Slot → the centre of that seat's box.
var seats := {}
var hand := Rect2()
## The centre of the hint pill's top edge.
var hint_anchor := Vector2.ZERO


## Lays the table out for [param avail], the screen's usable size in design
## pixels.
func solve(avail: Vector2) -> void:
	var need := required()
	var ref := PORTRAIT_REF if portrait else LANDSCAPE_REF
	need = need.max(ref)
	scale = minf(avail.x / need.x, avail.y / need.y)
	frame = avail / scale
	if portrait:
		_place_portrait()
	else:
		_place_landscape()


## The smallest frame this content fits in, in table units.
func required() -> Vector2:
	var trick := TrickCluster.half_extent(trick_width)
	if portrait:
		var w := 2.0 * (EDGE + side_seat.x / 2.0 + _side_inner() + GAP + trick.x)
		w = maxf(w, maxf(hud_size.x + _hud_pad().x * 2.0, top_seat.x + EDGE * 2.0))
		w = maxf(w, hint_size.x + EDGE * 2.0)
		return Vector2(w, _top_rim() + _above() + _below_portrait() + _bottom_reserve())
	var w := 2.0 * (EDGE + side_seat.x / 2.0 + _landscape_reach())
	w = maxf(w, 2.0 * (_hud_pad().x + maxf(hud_left, hud_right) + GAP) + top_seat.x)
	return Vector2(w, _top_rim() + _above() + _below_landscape() + _bottom_reserve())


# ------------------------------------------------------------------ portrait

func _place_portrait() -> void:
	var rim := _top_rim()
	var lowest := frame.y - _bottom_reserve()
	var trick := TrickCluster.half_extent(trick_width)
	center = Vector2(frame.x / 2.0, ((rim + _above()) + (lowest - _below_portrait())) / 2.0)
	# Standing, the side seats go out to the screen's edges and the top seat up
	# under the HUD, as far as the felt's proportions allow; on a screen of
	# another shape, one or the other comes in to the felt's rim.
	var a := frame.x / 2.0 - EDGE - side_seat.x / 2.0
	var b := minf(center.y - rim, a * PORTRAIT_ASPECT.y)
	a = clampf(b / PORTRAIT_ASPECT.x, _side_min(), a)
	b = maxf(b, _above())
	_place_common(a, b)
	hint_anchor = Vector2(center.x, center.y + maxf(trick.y, side_seat.y / 2.0) + GAP)


func _below_portrait() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	return maxf(trick.y, side_seat.y / 2.0) + GAP + hint_size.y


# ----------------------------------------------------------------- landscape

func _place_landscape() -> void:
	var rim := _top_rim()
	var lowest := frame.y - _bottom_reserve()
	center = Vector2(frame.x / 2.0, ((rim + _above()) + (lowest - _below_landscape())) / 2.0)
	# Lying down, the top seat sits level with the HUD and the side seats run
	# out toward the screen's sides, as far as the felt's proportions allow; on
	# a screen of another shape, one or the other comes in to the felt's rim.
	var b := center.y - rim
	var a := clampf(b * LANDSCAPE_ASPECT.y, _landscape_reach(), frame.x / 2.0 - EDGE - side_seat.x / 2.0)
	b = clampf(a / LANDSCAPE_ASPECT.x, _above(), b)
	_place_common(a, b)
	# In the player's own empty place among the played cards: on their turn it
	# says so right where their card will land.
	hint_anchor = Vector2(center.x, center.y + trick_width * CardView.FACE_ASPECT / 2.0 + GAP)


func _below_landscape() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	var hint := trick_width * CardView.FACE_ASPECT / 2.0 + GAP + hint_size.y
	return maxf(maxf(trick.y, side_seat.y / 2.0), hint)


## From the felt's centre to the side seats' avatars: the played cards (and the
## hint between them), then the seat's own reach toward the table.
func _landscape_reach() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	return maxf(trick.x, hint_size.x / 2.0) + GAP + _side_inner()


# -------------------------------------------------------------------- shared

func _place_common(a: float, b: float) -> void:
	var pad := _hud_pad()
	hud = Rect2(pad, Vector2(frame.x - pad.x * 2.0, hud_size.y))
	felt = Rect2(center - Vector2(a, b), Vector2(a, b) * 2.0)
	seats = {
		SeatView.Slot.TOP: Vector2(center.x, center.y - b),
		SeatView.Slot.LEFT: Vector2(center.x - a, center.y),
		SeatView.Slot.RIGHT: Vector2(center.x + a, center.y),
		SeatView.Slot.BOTTOM: Vector2(frame.x / 2.0, frame.y - _bottom_pad() - plate.y / 2.0),
	}
	var plate_top := frame.y - _bottom_pad() - plate.y
	var hand_top := plate_top + plate.y * PLATE_OVERLAP - HandFan.LIFT - hand_card.y
	var side := UI.sc(12, 7)
	hand = Rect2(side, hand_top, frame.x - side * 2.0, fan_height)


## The top seat's avatar centre, as high as it may go: under the HUD standing
## up, level with it lying down.
func _top_rim() -> float:
	var pad := _hud_pad()
	if portrait:
		return pad.y + hud_size.y + GAP + top_seat.y / 2.0
	return pad.y + maxf(hud_size.y, top_seat.y) / 2.0


## From the top seat's avatar down to the felt's centre, at the least: past the
## top seat's fan and the upper played card, with the side seats clear of the
## top seat (and, lying down, of the HUD).
func _above() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	var out := maxf(top_reach + GAP + trick.y, top_seat.y / 2.0 + GAP + side_seat.y / 2.0)
	if not portrait:
		out = maxf(out, _hud_pad().y + hud_size.y + GAP + side_seat.y / 2.0 - _top_rim())
	return out


## From the bottom of the frame up to the lowest the felt's contents may come:
## the plate, the hand over it, its cards raised on the player's turn, and a gap.
func _bottom_reserve() -> float:
	return _bottom_pad() + plate.y * (1.0 - PLATE_OVERLAP) + hand_card.y + HandFan.RAISE + GAP


## The closest the side seats' avatars may come to the felt's centre.
func _side_min() -> float:
	return _landscape_reach() if not portrait else _side_inner() + GAP + TrickCluster.half_extent(trick_width).x


## How far into the table a side seat reaches from its avatar's centre.
func _side_inner() -> float:
	return maxf(side_seat.x / 2.0, side_reach)


func _hud_pad() -> Vector2:
	return Vector2(UI.sc(12, 14), 8)


func _bottom_pad() -> float:
	return UI.sc(14, 4)
