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
## Two arrangements share every rule but where the seats go:
##
## * With the felt, the top seat sits on its top rim and the side seats on its
##   left and right rims, level with its centre, where the played cards gather.
## * [member open], with no felt, the side seats stand at the screen's left and
##   right edges and the top seat at its top edge, all centred along their
##   edge, and the played cards gather on the screen's own centre.
##
## Either way the player's own plate runs centred along the bottom edge under
## the hand, the played cards stay clear of every seat's face-down fan, and
## nothing that stays on screen through a trick touches anything else.

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
## No felt: the seats go out to the screen's edges and the played cards
## gather on the screen's centre.
var open := false
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
## Where the played cards gather: the felt's centre, or the screen's when
## [member open].
var center := Vector2.ZERO
## The felt, around [member center]. Laid out when [member open] too, though
## nothing draws it.
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
	if open:
		_place_open()
	elif portrait:
		_place_portrait()
	else:
		_place_landscape()
	_place_hint()


## The smallest frame this content fits in, in table units.
func required() -> Vector2:
	var w: float
	if portrait:
		w = 2.0 * (EDGE + side_seat.x / 2.0 + _side_inner() + GAP + TrickCluster.half_extent(trick_width).x)
		w = maxf(w, maxf(hud_size.x + _hud_pad().x * 2.0, top_seat.x + EDGE * 2.0))
		w = maxf(w, hint_size.x + EDGE * 2.0)
	else:
		w = 2.0 * (EDGE + side_seat.x / 2.0 + _landscape_reach())
		w = maxf(w, 2.0 * (_hud_pad().x + maxf(hud_left, hud_right) + GAP) + top_seat.x)
	var top := _top_rim() + _above()
	var bottom := _below() + _bottom_reserve()
	# Open, the played cards sit on the screen's centre, so whichever half needs
	# more room sets the height of both.
	return Vector2(w, 2.0 * maxf(top, bottom) if open else top + bottom)


# ------------------------------------------------------------------ placing

func _place_portrait() -> void:
	var rim := _top_rim()
	center = Vector2(frame.x / 2.0, ((rim + _above()) + (_lowest() - _below())) / 2.0)
	# Standing, the side seats go out to the screen's edges and the top seat up
	# under the HUD, as far as the felt's proportions allow; on a screen of
	# another shape, one or the other comes in to the felt's rim.
	var a := _edge_reach()
	var b := minf(center.y - rim, a * PORTRAIT_ASPECT.y)
	a = clampf(b / PORTRAIT_ASPECT.x, _side_min(), a)
	b = maxf(b, _above())
	_place_common(a, b)


func _place_landscape() -> void:
	var rim := _top_rim()
	center = Vector2(frame.x / 2.0, ((rim + _above()) + (_lowest() - _below())) / 2.0)
	# Lying down, the top seat sits level with the HUD and the side seats run
	# out toward the screen's sides, as far as the felt's proportions allow; on
	# a screen of another shape, one or the other comes in to the felt's rim.
	var b := center.y - rim
	var a := clampf(b * LANDSCAPE_ASPECT.y, _landscape_reach(), _edge_reach())
	b = clampf(a / LANDSCAPE_ASPECT.x, _above(), b)
	_place_common(a, b)


## No felt: every seat at its own edge of the screen, the played cards on the
## screen's centre.
func _place_open() -> void:
	center = frame / 2.0
	_place_common(_edge_reach(), center.y - _top_rim())


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


## Standing, under the played cards and the side seats; lying down, in the
## player's own empty place among the played cards, so on their turn it says
## so right where their card will land.
func _place_hint() -> void:
	if portrait:
		var trick := TrickCluster.half_extent(trick_width)
		hint_anchor = Vector2(center.x, center.y + maxf(trick.y, side_seat.y / 2.0) + GAP)
	else:
		hint_anchor = Vector2(center.x, center.y + trick_width * CardView.FACE_ASPECT / 2.0 + GAP)


# ----------------------------------------------------------------- measures

## The top seat's avatar centre, as high as it may go: under the HUD standing
## up, level with it lying down.
func _top_rim() -> float:
	var pad := _hud_pad()
	if portrait:
		return pad.y + hud_size.y + GAP + top_seat.y / 2.0
	return pad.y + maxf(hud_size.y, top_seat.y) / 2.0


## From the top seat's avatar down to the centre, at the least: past the top
## seat's fan and the upper played card, with the side seats clear of the top
## seat (and, lying down, of the HUD).
func _above() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	var out := maxf(top_reach + GAP + trick.y, top_seat.y / 2.0 + GAP + side_seat.y / 2.0)
	if not portrait:
		out = maxf(out, _hud_pad().y + hud_size.y + GAP + side_seat.y / 2.0 - _top_rim())
	return out


## From the centre down to the lowest the played cards, the side seats and the
## hint may come: standing, the hint goes under the lot; lying down, in the
## player's own place among the played cards.
func _below() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	var out := maxf(trick.y, side_seat.y / 2.0)
	if portrait:
		return out + GAP + hint_size.y
	return maxf(out, trick_width * CardView.FACE_ASPECT / 2.0 + GAP + hint_size.y)


## The lowest the table's contents may come, measured from the frame's top.
func _lowest() -> float:
	return frame.y - _bottom_reserve()


## From the bottom of the frame up to [method _lowest]: the plate, the hand over
## it, its cards raised on the player's turn, and a gap.
func _bottom_reserve() -> float:
	return _bottom_pad() + plate.y * (1.0 - PLATE_OVERLAP) + hand_card.y + HandFan.RAISE + GAP


## From the centre to a side seat's avatar with the seat at the screen's edge.
func _edge_reach() -> float:
	return frame.x / 2.0 - EDGE - side_seat.x / 2.0


## From the centre to the side seats' avatars, lying down, at the least: the
## played cards (and the hint between them), then the seat's own reach toward
## the table.
func _landscape_reach() -> float:
	var trick := TrickCluster.half_extent(trick_width)
	return maxf(trick.x, hint_size.x / 2.0) + GAP + _side_inner()


## The closest the side seats' avatars may come to the centre.
func _side_min() -> float:
	return _landscape_reach() if not portrait else _side_inner() + GAP + TrickCluster.half_extent(trick_width).x


## How far into the table a side seat reaches from its avatar's centre.
func _side_inner() -> float:
	return maxf(side_seat.x / 2.0, side_reach)


func _hud_pad() -> Vector2:
	return Vector2(UI.sc(12, 14), 8)


func _bottom_pad() -> float:
	return UI.sc(14, 4)
