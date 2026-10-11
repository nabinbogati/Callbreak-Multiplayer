class_name Motion
extends RefCounted

## Every gameplay timing in one place.
##
## Motion at the table is deliberately plain: cards slide in straight lines
## and nothing bounces, spins, flips in the air or pulses; the only glows are
## steady ones (the card winning the trick, the seat to act). Anything that
## moves is a node drawn once and moved by its transform, so a cheap phone keeps
## up, and anything that is not moving costs nothing — the engine stops drawing
## (see [method App._process]).
##
## Several timings have to agree with each other across widgets — the whole
## throw → hold → sweep sequence must finish inside the host's trick linger
## (1100 ms on the Go server; a LAN host or a solo table scales its own by its
## animation speed) or the trick is cleared mid-animation. Keeping them side by
## side makes those budgets visible.
##
## All values are base milliseconds at normal animation speed; scale them with
## [method scaled] and the player's animation-speed setting.

# ------------------------------------------------------------ trick cards

## A card sliding from a hand (or a seat) to its resting spot on the felt.
const THROW_MS := 280
## A finished trick lying still, all four cards readable, before it goes.
const TRICK_HOLD_MS := 300
## The cards sliding off toward the winner's seat, fading as they go.
const SWEEP_MS := 300
## Total on-screen life of a completed trick's animation. Must stay below the
## hosts' 1100 ms trick linger with headroom for a late frame.
const TRICK_ANIMATION_MS := THROW_MS + TRICK_HOLD_MS + SWEEP_MS

# ---------------------------------------------------------------- dealing

## Gap between consecutive cards leaving the deck.
const DEAL_GAP_MS := 56
## One card's slide from the deck to its seat.
const DEAL_FLIGHT_MS := 300
## The tail after the last card lands, before the overlay hands off.
const DEAL_OUTRO_MS := 140
## Whole deal, start to finish.
const DEAL_TOTAL_MS := DEAL_GAP_MS * 51 + DEAL_FLIGHT_MS + DEAL_OUTRO_MS
## [constant DEAL_TOTAL_MS] in seconds, for the hosts' pacing.
const DEAL_TOTAL := DEAL_TOTAL_MS / 1000.0

# ------------------------------------------------------------------- hand

## Legal cards rising when the turn comes round, and slots closing up.
const SLOT_MS := 180
## Press-and-hold preview growing in.
const PREVIEW_MS := 100


## [param scale] as applied to the trick sequence (throw, hold, sweep).
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

## Decelerating: quick off the mark, settling gently. The one curve for things
## moving into place. A closed form, so it is cheap to call per card per frame.
static func decelerate(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


## Accelerating: things leaving.
static func accelerate(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c
