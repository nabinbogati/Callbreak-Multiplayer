import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../state/app_settings.dart';
import 'suit_glyph.dart';

/// A card face. Every internal measurement is derived from [width] so the same
/// widget draws the hand card, the card on the felt and the settings preview.
///
/// Laid out like a real deck: the rank and suit in the top-left corner (the
/// only part a tightly overlapped fan shows), mirrored in the bottom-right,
/// and a large centre pip so a card lying on the felt reads from across the
/// table. Court cards carry their letter in the display face instead of a pip.
class PlayingCardView extends StatelessWidget {
  const PlayingCardView({
    super.key,
    required this.card,
    required this.width,
    this.dimmed = false,
    this.highlighted = false,
    this.elevation = 0,
  });

  final PlayingCard card;
  final double width;

  /// Illegal to play right now. Drawn as a dark veil over an opaque card
  /// rather than as transparency: overlapped fan cards then never show
  /// through one another, and no compositing layer is needed per card.
  final bool dimmed;

  /// Lit with a warm halo — a playable card on your turn, or the card
  /// currently winning the trick.
  final bool highlighted;

  /// 0 resting … 1 held high (being previewed or dragged); deepens the shadow
  /// so a lifted card visibly leaves the fan.
  final double elevation;

  static const aspect = 80 / 54;

  double get height => width * aspect;

  @override
  Widget build(BuildContext context) {
    final face = CardFacePalette.of(SettingsScope.of(context).cardStyle);
    final ink = card.suit.isRed ? face.red : face.ink;
    final radius = BorderRadius.circular(width * 0.11);
    final pad = width * 0.075;
    final e = elevation.clamp(0.0, 1.0);

    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(face.face, Colors.white, 0.06)!,
              face.face,
              Color.lerp(face.face, Colors.black, 0.07)!,
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
          borderRadius: radius,
          border: Border.all(
            color: card.isTrump ? face.trumpEdge : face.edge,
            width: card.isTrump ? width * 0.032 : width * 0.02,
          ),
          boxShadow: [
            if (highlighted)
              BoxShadow(
                color: AppColors.turnGlow.withValues(alpha: 0.75),
                blurRadius: width * 0.32,
                spreadRadius: width * 0.03,
              ),
            BoxShadow(
              color: Color.fromRGBO(0, 0, 0, 0.32 + 0.14 * e),
              blurRadius: width * (0.16 + 0.22 * e),
              offset: Offset(0, width * (0.08 + 0.16 * e)),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Trumps catch a little gold light in the corner, so spades are
            // findable in the fan even before the suit is read.
            if (card.isTrump)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.center,
                      colors: [
                        AppColors.goldMid.withValues(alpha: 0.32),
                        AppColors.goldMid.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              left: pad,
              top: pad * 0.55,
              child: _CornerIndex(card: card, ink: ink, width: width),
            ),
            Positioned.fill(
              child: Center(
                child: _CenterArt(card: card, ink: ink, width: width),
              ),
            ),
            Positioned(
              right: pad,
              bottom: pad * 0.55,
              child: RotatedBox(
                quarterTurns: 2,
                child: _CornerIndex(card: card, ink: ink, width: width),
              ),
            ),
            if (dimmed)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    color: const Color(0x8A0A1410),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Rank over suit, the way a real index reads.
class _CornerIndex extends StatelessWidget {
  const _CornerIndex({
    required this.card,
    required this.ink,
    required this.width,
  });

  final PlayingCard card;
  final Color ink;
  final double width;

  @override
  Widget build(BuildContext context) {
    final wide = card.label.length > 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          card.label,
          style: TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontWeight: FontWeight.w700,
            fontSize: width * (wide ? 0.25 : 0.28),
            height: 1.0,
            color: ink,
            // "10" is the one two-glyph rank; pull it together so it still
            // fits the sliver of card a full fan leaves visible.
            letterSpacing: wide ? -width * 0.025 : 0,
          ),
        ),
        SizedBox(height: width * 0.025),
        SuitGlyph(suit: card.suit, size: width * 0.17, color: ink),
      ],
    );
  }
}

/// The big centre mark: a pip for number cards, an oversized pip for the ace,
/// the letter for court cards.
class _CenterArt extends StatelessWidget {
  const _CenterArt({
    required this.card,
    required this.ink,
    required this.width,
  });

  final PlayingCard card;
  final Color ink;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (card.rank >= 11 && card.rank <= 13) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            card.label,
            style: TextStyle(
              fontFamily: 'Cinzel',
              fontWeight: FontWeight.w700,
              fontSize: width * 0.42,
              height: 1.05,
              color: ink,
            ),
          ),
          SuitGlyph(suit: card.suit, size: width * 0.16, color: ink),
        ],
      );
    }
    final size = card.rank == 14 ? width * 0.56 : width * 0.4;
    return SuitGlyph(suit: card.suit, size: size, color: ink);
  }
}

/// The back of a card, in the current table colourway: a gold-framed lattice
/// with a spade medallion. Same proportions as the face, so a dealt card turns
/// over into the hand without changing shape.
class CardBackView extends StatelessWidget {
  const CardBackView({
    super.key,
    required this.width,
    required this.palette,
    this.rotation = 0,
    this.shadow = true,
    this.spadeEmblem = false,
  });

  final double width;
  final ThemePalette palette;
  final double rotation;

  /// False for stacked layers (the dealing deck, the inner cards of a fan), so
  /// a pile of backs doesn't collapse into one dark blob of shadows.
  final bool shadow;

  /// True for the home hero's cards, which carry a larger glowing spade.
  final bool spadeEmblem;

  static const aspect = PlayingCardView.aspect;

  @override
  Widget build(BuildContext context) {
    final height = width * aspect;
    final radius = width * 0.11;

    final card = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.cardBack,
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: AppColors.goldBorder.withValues(alpha: 0.75),
          width: (width * 0.03).clamp(0.8, 3.0),
        ),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: const Color(0x66000000),
                  blurRadius: width * 0.18,
                  offset: Offset(0, width * 0.08),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(width * 0.085),
        child: CustomPaint(
          painter: _BackPatternPainter(
            radius: radius * 0.6,
            emblem: spadeEmblem
                ? _Emblem.hero
                : (width >= 34 ? _Emblem.medallion : _Emblem.none),
            fine: width < 34,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );

    if (rotation == 0) return card;
    return Transform.rotate(angle: rotation, child: card);
  }
}

enum _Emblem { none, medallion, hero }

class _BackPatternPainter extends CustomPainter {
  const _BackPatternPainter({
    required this.radius,
    required this.emblem,
    required this.fine,
  });

  final double radius;
  final _Emblem emblem;

  /// Small cards draw no lattice — see [paint].
  final bool fine;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final gold = AppColors.goldBorder;

    // Lattice. Small cards (the opponents' face-down fans — 39 of them on
    // screen at once) skip it: at that size it is noise, and drawn per card
    // it was hundreds of strokes and dozens of clips every frame. Larger
    // cards draw it as one cached path, trimmed to the frame by geometry
    // instead of a clip.
    if (!fine) {
      canvas.drawPath(
        _latticeFor(size),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = gold.withValues(alpha: 0.2)
          ..strokeWidth = 0.8,
      );
    }

    // Inner frame.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = fine ? 0.7 : 1
        ..color = gold.withValues(alpha: 0.45),
    );

    if (emblem == _Emblem.none) return;

    final c = size.center(Offset.zero);
    final heroic = emblem == _Emblem.hero;
    final r = size.width * (heroic ? 0.36 : 0.3);

    // A diamond medallion behind the spade.
    final medallion = Path()
      ..moveTo(c.dx, c.dy - r * 1.25)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r * 1.25)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(medallion, Paint()..color = const Color(0x99000000));
    canvas.drawPath(
      medallion,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = heroic ? 1.4 : 1
        ..color = gold.withValues(alpha: 0.8),
    );

    final glyph = size.width * (heroic ? 0.46 : 0.34);
    final spade = SuitPaths.of(Suit.spades);
    canvas.save();
    canvas.translate(c.dx - glyph / 2, c.dy - glyph / 2);
    canvas.scale(glyph, glyph);
    if (heroic) {
      canvas.drawPath(
        spade,
        Paint()
          ..color = AppColors.gold.withValues(alpha: 0.7)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.08),
      );
    }
    canvas.drawPath(
      spade,
      Paint()
        ..shader = goldTextGradient.createShader(
          const Rect.fromLTWH(0, 0, 1, 1),
        ),
    );
    canvas.restore();
  }

  static final Map<Size, Path> _lattices = {};

  /// Both diagonals of the lattice as a single path, each segment cut to the
  /// card's rectangle. Cached per size: the same few card sizes recur.
  static Path _latticeFor(Size size) {
    final cached = _lattices[size];
    if (cached != null) return cached;
    if (_lattices.length > 24) _lattices.clear();
    final w = size.width;
    final h = size.height;
    final step = w * 0.2;
    final path = Path();
    for (var d = -h; d < w; d += step) {
      // y = x - d (falling to the right) and y = d + h - x (rising), both kept
      // to 0 <= x <= w; the x-range is where each stays within 0..h.
      final x0 = math.max(0.0, d);
      final x1 = math.min(w, d + h);
      if (x1 <= x0) continue;
      path
        ..moveTo(x0, x0 - d)
        ..lineTo(x1, x1 - d)
        ..moveTo(x0, d + h - x0)
        ..lineTo(x1, d + h - x1);
    }
    return _lattices[size] = path;
  }

  @override
  bool shouldRepaint(_BackPatternPainter old) =>
      old.radius != radius || old.emblem != emblem || old.fine != fine;
}
