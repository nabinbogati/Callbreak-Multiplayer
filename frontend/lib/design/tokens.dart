import 'package:flutter/widgets.dart';

/// Design tokens lifted straight from the Call Break design component
/// (`Call Break.dc.html`). Nothing in the UI should hard-code a colour or a
/// type ramp — it all comes from here.
class AppColors {
  const AppColors._();

  // Gold — the brand accent, used for the wordmark, trump and the local player.
  static const goldLight = Color(0xFFFFF6D8);
  static const gold = Color(0xFFF5D78A);
  static const goldMid = Color(0xFFF0C75E);
  static const goldDeep = Color(0xFFC9922A);
  static const goldBorder = Color(0xFFE8B84A);

  // Text on the dark felt.
  static const textPrimary = Color(0xFFF2F7F4);
  static const textOnDark = Color(0xFFE8F5EE);
  static const textMuted = Color(0xFFA8C9B8);
  static const textSubtle = Color(0xFFC8E6D8);
  static const textFaint = Color(0xFF7FA896);

  // Card faces.
  static const cardFace = Color(0xFFF7F3EB);
  static const cardInk = Color(0xFF1A1A1A);
  static const cardRed = Color(0xFFC0392B);
  static const cardEdge = Color(0x1F1A1204);
  static const trumpEdge = Color(0xB3C9922A);

  static const success = Color(0xFF3DDC84);
  static const danger = Color(0xFFE85A4F);
  static const onGold = Color(0xFF1A1204);

  // Surfaces layered over the table gradient.
  static const panel = Color(0x8C04120D);
  static const panelSoft = Color(0x80061A14);
  static const hairline = Color(0x1FF2F7F4);
  static const hairlineStrong = Color(0x33F2F7F4);

  // Raised glass surfaces: dialogs, sheets, the bid panel, the scoreboard.
  // Two stops so a panel catches a little light along its top edge instead of
  // reading as a flat cut-out.
  static const surfaceTop = Color(0xF2102A20);
  static const surfaceBottom = Color(0xF5061510);

  /// Dims the table behind a modal decision.
  static const scrim = Color(0xA6000000);

  /// The "it's on you" accent: turn rings, the hand's under-glow.
  static const turnGlow = Color(0xFFFFD66B);
}

/// Elevation presets, so panels, cards and buttons cast consistent shadows
/// instead of each widget inventing its own blur.
class AppShadows {
  const AppShadows._();

  /// Chips and small plates resting on the felt.
  static const low = [
    BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 3)),
  ];

  /// Floating panels and dialogs.
  static const high = [
    BoxShadow(color: Color(0x99000000), blurRadius: 32, offset: Offset(0, 14)),
    BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2)),
  ];

  /// A coloured halo — selection, the active turn, the primary action.
  static List<BoxShadow> glow(Color color, {double strength = 1, double blur = 18}) => [
    BoxShadow(
      color: color.withValues(alpha: 0.45 * strength),
      blurRadius: blur,
      spreadRadius: 0.5 * strength,
    ),
  ];
}

/// The gradient every raised panel is painted with.
const surfaceGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [AppColors.surfaceTop, AppColors.surfaceBottom],
);

/// The gold fill of every primary action.
const goldButtonGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFFFE7A3), AppColors.goldMid, AppColors.goldDeep],
  stops: [0.0, 0.48, 1.0],
);

/// The four colourways the design ships. Emerald is the default.
enum TableTheme { emerald, sapphire, amethyst, crimson }

class ThemePalette {
  const ThemePalette({
    required this.label,
    required this.background,
    required this.tableBackground,
    required this.glow,
    required this.felt,
    required this.avatar,
    required this.cardBack,
  });

  final String label;

  /// Three-stop gradient behind the home screen.
  final List<Color> background;

  /// Three-stop gradient behind the table.
  final List<Color> tableBackground;

  /// Radial bloom colour used at low opacity behind the hero.
  final Color glow;

  /// Felt surface, centre outwards.
  final List<Color> felt;

  /// Opponent avatar fill, top to bottom.
  final List<Color> avatar;

  /// Card back fill, top to bottom.
  final List<Color> cardBack;

  static const _palettes = <TableTheme, ThemePalette>{
    TableTheme.emerald: ThemePalette(
      label: 'Emerald',
      background: [Color(0xFF061A14), Color(0xFF0D3D2C), Color(0xFF145C42)],
      tableBackground: [Color(0xFF04140F), Color(0xFF0A2F22), Color(0xFF0E4633)],
      glow: Color(0xFF1F8A5C),
      felt: [Color(0xFF1F7A54), Color(0xFF0F4D36), Color(0xFF083628)],
      avatar: [Color(0xFF2A6B52), Color(0xFF0F3D2C)],
      cardBack: [Color(0xFF2E6B52), Color(0xFF0A2E22)],
    ),
    TableTheme.sapphire: ThemePalette(
      label: 'Sapphire',
      background: [Color(0xFF06131A), Color(0xFF0D2E45), Color(0xFF145C82)],
      tableBackground: [Color(0xFF04121A), Color(0xFF0A2740), Color(0xFF0E3E5C)],
      glow: Color(0xFF2A78C4),
      felt: [Color(0xFF1F6FA0), Color(0xFF0F3D5C), Color(0xFF08283D)],
      avatar: [Color(0xFF2A5B82), Color(0xFF0F2A45)],
      cardBack: [Color(0xFF2E5E8A), Color(0xFF0A2038)],
    ),
    TableTheme.amethyst: ThemePalette(
      label: 'Amethyst',
      background: [Color(0xFF130619), Color(0xFF340D45), Color(0xFF54216E)],
      tableBackground: [Color(0xFF100616), Color(0xFF2A0D3A), Color(0xFF421457)],
      glow: Color(0xFF9642CC),
      felt: [Color(0xFF7A3EAA), Color(0xFF45215C), Color(0xFF2C1440)],
      avatar: [Color(0xFF5B2A7A), Color(0xFF26123A)],
      cardBack: [Color(0xFF5E2E82), Color(0xFF20103A)],
    ),
    TableTheme.crimson: ThemePalette(
      label: 'Crimson',
      background: [Color(0xFF190807), Color(0xFF451212), Color(0xFF6E1D1A)],
      tableBackground: [Color(0xFF150605), Color(0xFF3D0F0D), Color(0xFF5C1815)],
      glow: Color(0xFFD65444),
      felt: [Color(0xFFB0453A), Color(0xFF5C1815), Color(0xFF3D0F0D)],
      avatar: [Color(0xFF7A2E28), Color(0xFF3D1412)],
      cardBack: [Color(0xFF82322A), Color(0xFF380F0D)],
    ),
  };

  static ThemePalette of(TableTheme theme) => _palettes[theme]!;
}

/// Card-face colour styles. Independent of [TableTheme] — this is the paint
/// on the front of the card, not the felt or the card back. Classic mirrors
/// the app's original hardcoded look and is the default. `midnight` is the
/// one dark option. The remaining four (`emerald`, `sapphire`, `amethyst`,
/// `crimson`) are the full, saturated jewel tones themselves — the same rich
/// hue as the matching [TableTheme]'s felt, not a tint of it — so a player
/// can give their cards real colour, not just a hint of one.
enum CardStyle { classic, midnight, emerald, sapphire, amethyst, crimson }

class CardFacePalette {
  const CardFacePalette({
    required this.label,
    required this.face,
    required this.ink,
    required this.red,
    required this.edge,
    required this.trumpEdge,
  });

  final String label;

  /// Card background fill.
  final Color face;

  /// Rank/suit ink for black suits.
  final Color ink;

  /// Rank/suit ink for red suits.
  final Color red;

  /// Card border for non-trump cards.
  final Color edge;

  /// Card border when the card is in the trump suit.
  final Color trumpEdge;

  static const _palettes = <CardStyle, CardFacePalette>{
    CardStyle.classic: CardFacePalette(
      label: 'Classic',
      face: Color(0xFFF7F3EB),
      ink: Color(0xFF1A1A1A),
      red: Color(0xFFC0392B),
      edge: Color(0x1F1A1204),
      trumpEdge: Color(0xB3C9922A),
    ),
    CardStyle.midnight: CardFacePalette(
      label: 'Midnight',
      face: Color(0xFF1C1F26),
      ink: Color(0xFFEDEFF3),
      red: Color(0xFFFF6B5D),
      edge: Color(0x33FFFFFF),
      trumpEdge: Color(0xCCE8B84A),
    ),
    // The four below use the exact same hue as the matching TableTheme's
    // first felt stop (see ThemePalette.felt above) — full colour, not a
    // tint — so a "Sapphire" card is genuinely, unmistakably sapphire blue.
    // Faces this saturated need light ink to stay legible (the same move
    // Midnight already makes), and a brighter trumpEdge to stay visible.
    CardStyle.emerald: CardFacePalette(
      label: 'Emerald',
      face: Color(0xFF1F7A54),
      ink: Color(0xFFF1FAF4),
      red: Color(0xFFFF6F61),
      edge: Color(0x33FFFFFF),
      trumpEdge: Color(0xCCE8B84A),
    ),
    CardStyle.sapphire: CardFacePalette(
      label: 'Sapphire',
      face: Color(0xFF1F6FA0),
      ink: Color(0xFFEDF6FC),
      red: Color(0xFFFF6F61),
      edge: Color(0x33FFFFFF),
      trumpEdge: Color(0xCCE8B84A),
    ),
    CardStyle.amethyst: CardFacePalette(
      label: 'Amethyst',
      face: Color(0xFF7A3EAA),
      ink: Color(0xFFF6EEFC),
      red: Color(0xFFFF6F61),
      edge: Color(0x33FFFFFF),
      trumpEdge: Color(0xCCE8B84A),
    ),
    // Crimson's face is already red, so a same-hued "red" suit colour would
    // vanish into it — inverted here (light ink for black suits, a deep
    // near-black maroon for red suits) so both stay readable against a red
    // face instead of the usual light-face convention of dark ink either way.
    CardStyle.crimson: CardFacePalette(
      label: 'Crimson',
      face: Color(0xFFB0453A),
      ink: Color(0xFFFCEEEA),
      red: Color(0xFF2A0D0B),
      edge: Color(0x33FFFFFF),
      trumpEdge: Color(0xCCE8B84A),
    ),
  };

  static CardFacePalette of(CardStyle style) => _palettes[style]!;
}

/// Type ramp. `Cinzel` carries the wordmark, everything else is Plus Jakarta.
class AppText {
  const AppText._();

  static const _display = 'Cinzel';
  static const _sans = 'PlusJakartaSans';

  static TextStyle wordmark(double size) => TextStyle(
    fontFamily: _display,
    fontWeight: FontWeight.w700,
    fontSize: size,
    letterSpacing: size * 0.04,
    height: 1.36,
  );

  static TextStyle medium(double size, Color color, {double? letterSpacing}) => TextStyle(
    fontFamily: _sans,
    fontWeight: FontWeight.w500,
    fontSize: size,
    color: color,
    letterSpacing: letterSpacing,
    height: 1.25,
  );

  static TextStyle semiBold(double size, Color color, {double? letterSpacing}) =>
      TextStyle(
        fontFamily: _sans,
        fontWeight: FontWeight.w600,
        fontSize: size,
        color: color,
        letterSpacing: letterSpacing,
        height: 1.25,
      );

  static TextStyle bold(double size, Color color, {double? letterSpacing}) => TextStyle(
    fontFamily: _sans,
    fontWeight: FontWeight.w700,
    fontSize: size,
    color: color,
    letterSpacing: letterSpacing,
    height: 1.25,
  );
}

/// The gold gradient the wordmark is painted with.
const goldTextGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [AppColors.goldLight, AppColors.goldMid, AppColors.goldDeep],
  stops: [0.0, 0.5, 1.0],
);
