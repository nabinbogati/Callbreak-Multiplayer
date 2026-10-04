class_name Tokens
extends RefCounted

## Design tokens lifted straight from the Call Break design. Nothing in the UI
## should hard-code a colour or a font — it all comes from here.

# Gold — the brand accent, used for the wordmark, trump and the local player.
const GOLD_LIGHT := Color("#FFF6D8")
const GOLD := Color("#F5D78A")
const GOLD_MID := Color("#F0C75E")
const GOLD_DEEP := Color("#C9922A")
const GOLD_BORDER := Color("#E8B84A")

# Text on the dark felt.
const TEXT_PRIMARY := Color("#F2F7F4")
const TEXT_ON_DARK := Color("#E8F5EE")
const TEXT_MUTED := Color("#A8C9B8")
const TEXT_SUBTLE := Color("#C8E6D8")
const TEXT_FAINT := Color("#7FA896")

const SUCCESS := Color("#3DDC84")
const DANGER := Color("#E85A4F")
const ON_GOLD := Color("#1A1204")

# Surfaces layered over the table gradient (ARGB in the design → RGBA here).
const PANEL := Color(0.0157, 0.0706, 0.051, 0.55)
const PANEL_SOFT := Color(0.0235, 0.102, 0.0784, 0.5)
const PANEL_SOLID := Color("#04120D")
const DIALOG := Color(0.0157, 0.0706, 0.051, 0.9)
const CHIP := Color(0.0157, 0.0706, 0.051, 0.82)
const HAIRLINE := Color(0.949, 0.969, 0.957, 0.12)
const HAIRLINE_STRONG := Color(0.949, 0.969, 0.957, 0.2)
const SCRIM := Color(0, 0, 0, 0.6)

# Raised glass surfaces: dialogs, sheets, the bid panel, the scoreboard. Two
# stops so a panel catches a little light along its top edge instead of
# reading as a flat cut-out.
const SURFACE_TOP := Color("#102A20F2")
const SURFACE_BOTTOM := Color("#061510F5")
## The gradient every raised panel is painted with, top to bottom.
const SURFACE := [SURFACE_TOP, SURFACE_BOTTOM]
## Dims the table behind a modal decision.
const MODAL_SCRIM := Color("#000000A6")
## The "it's on you" accent: turn rings, the hand's under-glow.
const TURN_GLOW := Color("#FFD66B")
## The gold fill of every primary action, top to bottom, at [constant GOLD_BUTTON_STOPS].
const GOLD_BUTTON := [Color("#FFE7A3"), GOLD_MID, GOLD_DEEP]
const GOLD_BUTTON_STOPS := [0.0, 0.48, 1.0]
## The gold the wordmark (and every gold number) is painted with.
const GOLD_TEXT := [GOLD_LIGHT, GOLD_MID, GOLD_DEEP]

# Elevation presets, so panels, cards and buttons cast consistent shadows
# instead of each widget inventing its own blur. Each is [colour, blur, offset].
## Chips and small plates resting on the felt.
const SHADOW_LOW := [[Color("#00000066"), 10.0, Vector2(0, 3)]]
## Floating panels and dialogs.
const SHADOW_HIGH := [[Color("#00000099"), 32.0, Vector2(0, 14)], [Color("#00000040"), 6.0, Vector2(0, 2)]]


## A coloured halo — selection, the active turn, the primary action.
static func glow(color: Color, strength := 1.0, blur := 18.0) -> Array:
	return [[Color(color, 0.45 * strength), blur, Vector2.ZERO, 0.5 * strength]]

const THEMES := ["emerald", "sapphire", "amethyst", "crimson"]

## The four colourways the design ships. Emerald is the default.
const PALETTES := {
	"emerald": {
		"label": "Emerald",
		"background": [Color("#061A14"), Color("#0D3D2C"), Color("#145C42")],
		"table": [Color("#04140F"), Color("#0A2F22"), Color("#0E4633")],
		"glow": Color("#1F8A5C"),
		"felt": [Color("#1F7A54"), Color("#0F4D36"), Color("#083628")],
		"avatar": [Color("#2A6B52"), Color("#0F3D2C")],
		"card_back": [Color("#2E6B52"), Color("#0A2E22")],
	},
	"sapphire": {
		"label": "Sapphire",
		"background": [Color("#06131A"), Color("#0D2E45"), Color("#145C82")],
		"table": [Color("#04121A"), Color("#0A2740"), Color("#0E3E5C")],
		"glow": Color("#2A78C4"),
		"felt": [Color("#1F6FA0"), Color("#0F3D5C"), Color("#08283D")],
		"avatar": [Color("#2A5B82"), Color("#0F2A45")],
		"card_back": [Color("#2E5E8A"), Color("#0A2038")],
	},
	"amethyst": {
		"label": "Amethyst",
		"background": [Color("#130619"), Color("#340D45"), Color("#54216E")],
		"table": [Color("#100616"), Color("#2A0D3A"), Color("#421457")],
		"glow": Color("#9642CC"),
		"felt": [Color("#7A3EAA"), Color("#45215C"), Color("#2C1440")],
		"avatar": [Color("#5B2A7A"), Color("#26123A")],
		"card_back": [Color("#5E2E82"), Color("#20103A")],
	},
	"crimson": {
		"label": "Crimson",
		"background": [Color("#190807"), Color("#451212"), Color("#6E1D1A")],
		"table": [Color("#150605"), Color("#3D0F0D"), Color("#5C1815")],
		"glow": Color("#D65444"),
		"felt": [Color("#B0453A"), Color("#5C1815"), Color("#3D0F0D")],
		"avatar": [Color("#7A2E28"), Color("#3D1412")],
		"card_back": [Color("#82322A"), Color("#380F0D")],
	},
}

const CARD_STYLES := ["classic", "midnight", "emerald", "sapphire", "amethyst", "crimson"]

## Card-face colour styles, independent of the table theme. Classic is the
## default; the jewel tones use the matching theme's full felt hue with light
## ink, and Crimson inverts its red suits so they stay readable on a red face.
const CARD_FACES := {
	"classic": {"label": "Classic", "face": Color("#F7F3EB"), "ink": Color("#1A1A1A"),
		"red": Color("#C0392B"), "edge": Color(0.102, 0.071, 0.016, 0.12), "trump_edge": Color(0.788, 0.573, 0.165, 0.7)},
	"midnight": {"label": "Midnight", "face": Color("#1C1F26"), "ink": Color("#EDEFF3"),
		"red": Color("#FF6B5D"), "edge": Color(1, 1, 1, 0.2), "trump_edge": Color(0.91, 0.722, 0.29, 0.8)},
	"emerald": {"label": "Emerald", "face": Color("#1F7A54"), "ink": Color("#F1FAF4"),
		"red": Color("#FF6F61"), "edge": Color(1, 1, 1, 0.2), "trump_edge": Color(0.91, 0.722, 0.29, 0.8)},
	"sapphire": {"label": "Sapphire", "face": Color("#1F6FA0"), "ink": Color("#EDF6FC"),
		"red": Color("#FF6F61"), "edge": Color(1, 1, 1, 0.2), "trump_edge": Color(0.91, 0.722, 0.29, 0.8)},
	"amethyst": {"label": "Amethyst", "face": Color("#7A3EAA"), "ink": Color("#F6EEFC"),
		"red": Color("#FF6F61"), "edge": Color(1, 1, 1, 0.2), "trump_edge": Color(0.91, 0.722, 0.29, 0.8)},
	"crimson": {"label": "Crimson", "face": Color("#B0453A"), "ink": Color("#FCEEEA"),
		"red": Color("#2A0D0B"), "edge": Color(1, 1, 1, 0.2), "trump_edge": Color(0.91, 0.722, 0.29, 0.8)},
}

# ------------------------------------------------------------------ fonts

## Where the baseline sits in a one-em-tall line (Flutter's `height: 1.0`),
## as a fraction of the font size: ascent / (ascent + descent) from each
## face's own metrics.
const SANS_BASELINE := 1.038 / 1.26
const DISPLAY_BASELINE := 0.976 / 1.348

static var _fonts := {}


## `weight` is one of "medium", "semibold", "bold", "display" (Cinzel, the
## wordmark face) or "icons" (the Material icon glyphs [Draw.icon] uses).
static func font(weight := "medium") -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var path: String = {
		"medium": "res://assets/fonts/PlusJakartaSans-Medium.ttf",
		"semibold": "res://assets/fonts/PlusJakartaSans-SemiBold.ttf",
		"bold": "res://assets/fonts/PlusJakartaSans-Bold.ttf",
		"display": "res://assets/fonts/Cinzel-Bold.ttf",
		"icons": "res://assets/fonts/MaterialIcons-Subset.otf",
	}.get(weight, "res://assets/fonts/PlusJakartaSans-Medium.ttf")
	var f: Font = load(path)
	if f == null:
		f = ThemeDB.fallback_font
	_fonts[weight] = f
	return f


static func palette(theme: String) -> Dictionary:
	return PALETTES.get(theme, PALETTES["emerald"])


static func card_face(style: String) -> Dictionary:
	return CARD_FACES.get(style, CARD_FACES["classic"])
