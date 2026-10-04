import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../engine/card.dart';

/// A suit symbol drawn as a vector path rather than a font glyph.
///
/// The ♠♥♦♣ code points are not in the app's own fonts, so as text they fall
/// back to whatever the device happens to ship — a different shape on every
/// manufacturer, and on some a full-colour emoji heart. Paths look the same
/// everywhere, stay crisp at any size, and can be tinted freely.
class SuitGlyph extends StatelessWidget {
  const SuitGlyph({
    super.key,
    required this.suit,
    required this.size,
    required this.color,
  });

  final Suit suit;

  /// Height of the glyph; width follows from the suit's own proportions.
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size * SuitPaths.aspect(suit), size),
      painter: SuitPainter(suit: suit, color: color),
    );
  }
}

class SuitPainter extends CustomPainter {
  const SuitPainter({required this.suit, required this.color, this.shadow});

  final Suit suit;
  final Color color;

  /// Optional soft drop shadow, for glyphs sitting on busy backgrounds.
  final Color? shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = SuitPaths.of(suit);
    canvas.save();
    canvas.scale(size.width, size.height);
    if (shadow != null) {
      canvas.drawPath(
        path.shift(const Offset(0, 0.04)),
        Paint()
          ..color = shadow!
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.04),
      );
    }
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SuitPainter old) =>
      old.suit != suit || old.color != color || old.shadow != shadow;
}

/// Unit-square suit outlines (0..1 on both axes), built once and reused.
class SuitPaths {
  const SuitPaths._();

  static final Map<Suit, ui.Path> _cache = {};

  /// Width relative to height, so glyphs keep their natural proportions.
  static double aspect(Suit suit) => switch (suit) {
    Suit.diamonds => 0.82,
    _ => 1.0,
  };

  static ui.Path of(Suit suit) => _cache[suit] ??= _build(suit);

  static ui.Path _build(Suit suit) => switch (suit) {
    Suit.hearts => _heart(),
    Suit.diamonds => _diamond(),
    Suit.spades => _spade(),
    Suit.clubs => _club(),
  };

  static ui.Path _heart() => ui.Path()
    ..moveTo(0.5, 0.95)
    ..cubicTo(0.2, 0.72, 0.0, 0.52, 0.0, 0.3)
    ..cubicTo(0.0, 0.13, 0.12, 0.03, 0.27, 0.03)
    ..cubicTo(0.38, 0.03, 0.46, 0.09, 0.5, 0.19)
    ..cubicTo(0.54, 0.09, 0.62, 0.03, 0.73, 0.03)
    ..cubicTo(0.88, 0.03, 1.0, 0.13, 1.0, 0.3)
    ..cubicTo(1.0, 0.52, 0.8, 0.72, 0.5, 0.95)
    ..close();

  static ui.Path _diamond() => ui.Path()
    ..moveTo(0.5, 0.0)
    ..quadraticBezierTo(0.7, 0.3, 1.0, 0.5)
    ..quadraticBezierTo(0.7, 0.7, 0.5, 1.0)
    ..quadraticBezierTo(0.3, 0.7, 0.0, 0.5)
    ..quadraticBezierTo(0.3, 0.3, 0.5, 0.0)
    ..close();

  static ui.Path _spade() {
    final body = ui.Path()
      ..moveTo(0.5, 0.0)
      ..cubicTo(0.64, 0.17, 1.0, 0.36, 1.0, 0.6)
      ..cubicTo(1.0, 0.75, 0.88, 0.84, 0.75, 0.84)
      ..cubicTo(0.65, 0.84, 0.57, 0.79, 0.53, 0.72)
      ..lineTo(0.47, 0.72)
      ..cubicTo(0.43, 0.79, 0.35, 0.84, 0.25, 0.84)
      ..cubicTo(0.12, 0.84, 0.0, 0.75, 0.0, 0.6)
      ..cubicTo(0.0, 0.36, 0.36, 0.17, 0.5, 0.0)
      ..close();
    return ui.Path.combine(ui.PathOperation.union, body, _stem());
  }

  static ui.Path _club() {
    var path = ui.Path()
      ..addOval(Rect.fromCircle(center: const Offset(0.5, 0.26), radius: 0.22));
    for (final leaf in [
      ui.Path()..addOval(
        Rect.fromCircle(center: const Offset(0.24, 0.57), radius: 0.22),
      ),
      ui.Path()..addOval(
        Rect.fromCircle(center: const Offset(0.76, 0.57), radius: 0.22),
      ),
      ui.Path()..addOval(
        Rect.fromCircle(center: const Offset(0.5, 0.5), radius: 0.14),
      ),
      _stem(),
    ]) {
      path = ui.Path.combine(ui.PathOperation.union, path, leaf);
    }
    return path;
  }

  /// The flared foot shared by spades and clubs.
  static ui.Path _stem() => ui.Path()
    ..moveTo(0.46, 0.6)
    ..quadraticBezierTo(0.45, 0.9, 0.3, 1.0)
    ..lineTo(0.7, 1.0)
    ..quadraticBezierTo(0.55, 0.9, 0.54, 0.6)
    ..close();
}
