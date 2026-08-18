import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../state/app_settings.dart';

/// A card face. Every internal measurement is derived from [width] so the same
/// widget draws the 54pt hand card and the 44pt card on the felt.
class PlayingCardView extends StatelessWidget {
  const PlayingCardView({
    super.key,
    required this.card,
    required this.width,
    this.dimmed = false,
    this.highlighted = false,
  });

  final PlayingCard card;
  final double width;

  /// Illegal to play right now — greyed back so the legal cards read first.
  final bool dimmed;

  /// Lifted with a gold glow (the playable-and-hovered state in the design).
  final bool highlighted;

  static const aspect = 80 / 54;

  double get height => width * aspect;

  @override
  Widget build(BuildContext context) {
    final facePalette = CardFacePalette.of(SettingsScope.of(context).cardStyle);
    final inkColor = card.suit.isRed ? facePalette.red : facePalette.ink;
    final radius = width * (7 / 54);
    final pad = width * (6 / 54);

    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: facePalette.face,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: card.isTrump ? facePalette.trumpEdge : facePalette.edge,
            width: card.isTrump ? width * (1.5 / 54) : width * (1 / 54),
          ),
          boxShadow: [
            if (highlighted)
              BoxShadow(
                color: AppColors.goldDeep.withValues(alpha: 0.45),
                blurRadius: width * (16 / 54),
                offset: Offset(0, width * (8 / 54)),
              )
            else
              BoxShadow(
                color: const Color(0x4D000000),
                blurRadius: width * (10 / 54),
                offset: Offset(0, width * (6 / 54)),
              ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Text(card.label, style: AppText.bold(width * (14 / 54), inkColor)),
              SizedBox(height: width * (2 / 54)),
              Text(card.suit.symbol, style: AppText.bold(width * (16 / 54), inkColor)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The back of a card, in the current table colourway.
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

  /// False for the offset layers of the dealing deck, so a stack of card backs
  /// doesn't collapse into one dark blob of overlapping shadows.
  final bool shadow;

  /// True for the home hero's cards, which carry a golden spade badge with a
  /// soft glow.
  final bool spadeEmblem;

  static const aspect = 100 / 72;

  @override
  Widget build(BuildContext context) {
    final height = width * aspect;
    final radius = width * (8 / 72);

    return Transform.rotate(
      angle: rotation,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: palette.cardBack,
          ),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: AppColors.goldBorder.withValues(alpha: 0.7),
            width: width * (1.5 / 72),
          ),
          boxShadow: [
            if (shadow)
              const BoxShadow(
                color: Color(0x59000000),
                blurRadius: 12,
                offset: Offset(0, 6),
              ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(width * (8 / 72)),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: AppColors.goldBorder.withValues(alpha: 0.4),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(radius * 0.5),
            ),
            child: spadeEmblem
                ? Center(
                    child: Container(
                      width: width * (34 / 72),
                      height: width * (34 / 72),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.gold.withValues(alpha: 0.4),
                            blurRadius: width * (10 / 72),
                            spreadRadius: width * (1.5 / 72),
                          ),
                        ],
                      ),
                      child: Text(
                        // \uFE0E forces text presentation so this is a clean
                        // black spade glyph, lit by golden shine (the shadows)
                        // and the golden halo circle behind it. The generous
                        // line height stops the glyph's point from clipping.
                        '♠\uFE0E',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: width * (24 / 72),
                          height: 1.6,
                          color: Colors.black,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(
                              color: AppColors.gold,
                              blurRadius: width * (5 / 72),
                            ),
                            Shadow(
                              color: AppColors.goldDeep.withValues(alpha: 0.8),
                              blurRadius: width * (2 / 72),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

