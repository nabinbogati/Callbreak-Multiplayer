class_name HintLine
extends Control

## One line of help above the hand: whose move it is, or why a card was
## refused ("Follow suit — play a heart"). Each change pops the new pill in
## over the old one fading away.

enum Tone { TURN, REFUSED, INFO }

static var _widest := Vector2.ZERO

## The hint to show — `{"text", "tone", "suit", "icon"}` — or empty for none.
var hint := {}:
	set(v):
		hint = v
		_retarget()
## Whether it is this player's move, which shows "Your turn" when there is
## nothing more specific to say.
var your_turn := false:
	set(v):
		your_turn = v
		_retarget()
## Where the pill goes: the centre of its top edge.
var anchor_center := Vector2.ZERO

var _current := {}
var _previous := {}
var _t := 1.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


static func make(text: String, tone: int, suit := -1, icon := "") -> Dictionary:
	return {"text": text, "tone": tone, "suit": suit, "icon": icon}


static func your_turn_hint() -> Dictionary:
	return make("Your turn", Tone.TURN, -1, "touch_app_rounded")


static func waiting() -> Dictionary:
	return make("Wait for your turn", Tone.INFO, -1, "hourglass_top_rounded")


## Explains, from the rules, why [param card] cannot be played into the trick.
static func illegal(view: GameView, card: String) -> Dictionary:
	var trick := view.trick
	if trick.is_empty():
		return _cannot()
	var led := Cards.suit(trick[0]["card"])
	var hand := view.hand
	if hand.any(func(c): return Cards.suit(c) == led):
		return _follow(led) if Cards.suit(card) != led else _beat(led)
	if hand.any(func(c): return Cards.is_trump(c)):
		var trumped := trick.any(func(p): return Cards.is_trump(p["card"]))
		return _overtrump() if trumped else _must_trump(led)
	return _cannot()


static func _cannot() -> Dictionary:
	return make("That card can't be played right now", Tone.REFUSED, -1, "block_rounded")


static func _follow(led: int) -> Dictionary:
	return make("Follow suit — play a %s" % _one(led), Tone.REFUSED, led)


static func _beat(led: int) -> Dictionary:
	return make("Beat the trick — play a higher %s" % _one(led), Tone.REFUSED, led)


static func _overtrump() -> Dictionary:
	return make("Overtrump — play a higher spade", Tone.REFUSED, Cards.Suit.SPADES)


static func _must_trump(led: int) -> Dictionary:
	return make("No %ss left — you must play a spade" % _one(led), Tone.REFUSED, Cards.Suit.SPADES)


## The largest pill any hint can need, so the table can keep room for it.
static func widest_size() -> Vector2:
	if _widest == Vector2.ZERO:
		var all := [your_turn_hint(), waiting(), _cannot(), _overtrump()]
		for suit in 4:
			all.append_array([_follow(suit), _beat(suit), _must_trump(suit)])
		for h in all:
			_widest = _widest.max(_pill_size(h))
	return _widest


static func _one(suit: int) -> String:
	return ["spade", "heart", "diamond", "club"][suit]


## What is on screen now, as plain text (empty for nothing) — for tests.
func shown_text() -> String:
	return str(_current.get("text", ""))


func _retarget() -> void:
	var next := hint if not hint.is_empty() else (your_turn_hint() if your_turn else {})
	if next.get("text", "") == _current.get("text", "") and next.get("tone", -1) == _current.get("tone", -1):
		return
	_previous = _current
	_current = next
	_t = 0.0
	set_process(true)
	reposition()


func reposition() -> void:
	var s := _pill_size(_current) if not _current.is_empty() else _pill_size(_previous)
	size = s
	position = Vector2(anchor_center.x - s.x / 2.0, anchor_center.y)
	queue_redraw()


func _process(delta: float) -> void:
	_t = minf(_t + delta / 0.22, 1.0)
	if _t >= 1.0:
		_previous = {}
		set_process(false)
	queue_redraw()


static func _fg(h: Dictionary) -> Color:
	match h["tone"]:
		Tone.TURN: return Tokens.ON_GOLD
		Tone.REFUSED: return Color("#FFB4AC")
	return Tokens.TEXT_ON_DARK


static func _pill_size(h: Dictionary) -> Vector2:
	if h.is_empty():
		return Vector2.ZERO
	var tw := Tokens.font("bold").get_string_size(h["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var glyph := 13.0 * Draw.suit_aspect(h["suit"]) if h["suit"] >= 0 else (14.0 if h["icon"] != "" else 0.0)
	return Vector2(12 + glyph + 6 + tw + 12, 6 + maxf(12 * 1.25, 14) + 6)


func _draw() -> void:
	if not _previous.is_empty() and _t < 1.0:
		var out := 1.0 - Motion.ease_in(_t)
		_draw_pill(_previous, out, 0.85 + 0.15 * out)
	if not _current.is_empty():
		var e := Motion.ease_out_back(_t)
		_draw_pill(_current, clampf(e, 0.0, 1.0), 0.85 + 0.15 * e)


func _draw_pill(h: Dictionary, alpha: float, scale: float) -> void:
	if alpha <= 0.01:
		return
	var s := _pill_size(h)
	var origin := (size - s) / 2.0
	draw_set_transform(origin + s / 2.0 * (1.0 - scale), 0.0, Vector2.ONE * scale)
	var rect := Rect2(Vector2.ZERO, s)
	var turn: bool = h["tone"] == Tone.TURN
	var refused: bool = h["tone"] == Tone.REFUSED
	var fade := func(c: Color) -> Color: return Color(c, c.a * alpha)
	var shadows: Array = Tokens.glow(Tokens.GOLD_DEEP, 0.9) if turn else Tokens.SHADOW_LOW
	Draw.box_shadow(self, rect, 20, shadows.map(func(e): return [fade.call(e[0])] + e.slice(1)))
	var pts := Draw.rounded_rect_points(rect, 20, 8)
	var tint := Color(1, 1, 1, alpha)
	if turn:
		Draw.fill_linear(self, pts, Vector2.ZERO, Vector2(0, s.y), Tokens.GOLD_BUTTON, Tokens.GOLD_BUTTON_STOPS, true, tint)
	else:
		Draw.fill_linear(self, pts, Vector2.ZERO, Vector2(0, s.y), Tokens.SURFACE, [], true, tint)
	var border := Color("#FFF6D866") if turn else (Color(Tokens.DANGER, 0.7) if refused else Tokens.HAIRLINE_STRONG)
	Draw.stroke_rounded_rect(self, rect, 20, fade.call(border), 1.0)
	var fg: Color = fade.call(_fg(h))
	var x := 12.0
	var cy := s.y / 2.0
	if h["suit"] >= 0:
		var red: bool = h["suit"] == Cards.Suit.HEARTS or h["suit"] == Cards.Suit.DIAMONDS
		var gw := 13.0 * Draw.suit_aspect(h["suit"])
		Draw.suit(self, h["suit"], Vector2(x + gw / 2.0, cy), 13, fade.call(Color("#FF8A7E") if red else Tokens.TEXT_PRIMARY))
		x += gw
	elif h["icon"] != "":
		Draw.icon(self, h["icon"], Rect2(x, cy - 7, 14, 14), fg)
		x += 14
	x += 6
	draw_string(Tokens.font("bold"), Vector2(x, cy + 12 * 1.25 * (Tokens.SANS_BASELINE - 0.5)), h["text"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, fg)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
