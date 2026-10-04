class_name Motion
extends RefCounted

## Every gameplay timing in one place.
##
## Several of these have to agree with each other across widgets — a thrown
## card's top-level flight and the copy [TrickCluster] settles on the felt run
## the same path for the same length of time, and the whole throw → gather →
## sweep sequence must finish inside the host's trick linger (1100 ms on the
## Go server, the LAN host and the solo table alike) or the trick is cleared
## mid-animation. Keeping them side by side makes those budgets visible.
##
## All values are base milliseconds at normal animation speed; scale them with
## [method scaled] and the player's animation-speed setting.

# ------------------------------------------------------------ trick cards

## A card travelling from a hand (or a seat) to its resting spot on the felt.
const THROW_MS := 380
## Once a trick is decided, the four cards first slide together onto the
## winning card…
const GATHER_MS := 170
## …then the stack sweeps off toward the winner's seat.
const SWEEP_MS := 330
## Total on-screen life of a completed trick's animation. Must stay below the
## hosts' 1100 ms trick linger with headroom for a late frame.
const TRICK_ANIMATION_MS := THROW_MS + GATHER_MS + SWEEP_MS

# ---------------------------------------------------------------- dealing

## The deck dropping onto the felt.
const DEAL_INTRO_MS := 180
## Two quick riffles before the first card goes out.
const SHUFFLE_MS := 440
## Gap between consecutive cards leaving the deck.
const DEAL_GAP_MS := 44
## One card's flight from the deck to its seat.
const DEAL_FLIGHT_MS := 360
## The tail after the last card lands, before the overlay hands off.
const DEAL_OUTRO_MS := 140
## Whole deal, start to finish.
const DEAL_TOTAL_MS := DEAL_INTRO_MS + SHUFFLE_MS + DEAL_GAP_MS * 51 + DEAL_FLIGHT_MS + DEAL_OUTRO_MS
## [constant DEAL_TOTAL_MS] in seconds, for the hosts' pacing.
const DEAL_TOTAL := DEAL_TOTAL_MS / 1000.0

# ------------------------------------------------------------------- hand

## Legal cards rising when the turn comes round, and slots closing up.
const SLOT_MS := 220
## Press-and-hold preview growing in.
const PREVIEW_MS := 130
## A dealt card turning face up in the hand.
const REVEAL_MS := 200


## [param scale] as applied to the trick sequence (throw, gather, sweep).
## Capped so that even on "slow" the whole sequence still fits a networked
## host's fixed 1100 ms linger — past it the server clears the trick and the
## cards would vanish mid-sweep. (A solo table stretches its own linger with the
## setting, so the cap only ever shortens the wait there.)
static func trick_scale(scale: float) -> float:
	return 1040.0 / TRICK_ANIMATION_MS if scale * TRICK_ANIMATION_MS > 1040 else scale


## [param base_ms] at [param scale], in seconds.
static func scaled(base_ms: float, scale: float) -> float:
	return roundf(base_ms * scale) / 1000.0


# ----------------------------------------------------------------- curves

## Material 3's emphasized curve: quick to start, long gentle settle.
static func emphasized(t: float) -> float:
	return cubic(0.2, 0.0, 0.0, 1.0, t)


## Decelerating entrance — things arriving on screen.
static func enter(t: float) -> float:
	return cubic(0.05, 0.7, 0.1, 1.0, t)


## Accelerating exit — things leaving.
static func exit(t: float) -> float:
	return cubic(0.3, 0.0, 0.8, 0.15, t)


static func ease_out_cubic(t: float) -> float:
	return cubic(0.215, 0.61, 0.355, 1.0, t)


static func ease_in_cubic(t: float) -> float:
	return cubic(0.55, 0.055, 0.675, 0.19, t)


static func ease_out_back(t: float) -> float:
	return cubic(0.175, 0.885, 0.32, 1.275, t)


static func ease_out(t: float) -> float:
	return cubic(0.0, 0.0, 0.58, 1.0, t)


static func ease_in(t: float) -> float:
	return cubic(0.42, 0.0, 1.0, 1.0, t)


## An overshooting spring that settles, period 0.4.
static func elastic_out(t: float) -> float:
	const PERIOD := 0.4
	var s := PERIOD / 4.0
	return pow(2.0, -10.0 * t) * sin((t - s) * TAU / PERIOD) + 1.0


## A CSS-style cubic Bézier easing through (0,0), (a,b), (c,d), (1,1),
## evaluated the way Flutter's `Cubic` is: x is solved for by bisection.
static func cubic(a: float, b: float, c: float, d: float, t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	var start := 0.0
	var end := 1.0
	while true:
		var mid := (start + end) / 2.0
		var estimate := _bezier(a, c, mid)
		if absf(t - estimate) < 0.001:
			return _bezier(b, d, mid)
		if estimate < t:
			start = mid
		else:
			end = mid
	return t


static func _bezier(p1: float, p2: float, m: float) -> float:
	return 3.0 * p1 * (1.0 - m) * (1.0 - m) * m + 3.0 * p2 * (1.0 - m) * m * m + m * m * m
