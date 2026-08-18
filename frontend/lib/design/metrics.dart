import 'package:flutter/widgets.dart';

/// The design is drawn at 390×844 portrait and 844×390 landscape, i.e. a 390pt
/// short side in both. [Metrics] converts those design pixels into real ones so
/// the layout keeps its proportions on any handset, with a ceiling so a tablet
/// does not end up with comically large cards.
class Metrics extends InheritedWidget {
  Metrics({super.key, required this.size, required super.child})
    : isPortrait = size.height >= size.width,
      scale = _scaleFor(size);

  final Size size;
  final bool isPortrait;
  final double scale;

  static const designShortSide = 390.0;
  static const _maxScale = 1.4;
  static const _minScale = 0.78;

  static double _scaleFor(Size size) {
    final shortSide = size.shortestSide;
    return (shortSide / designShortSide).clamp(_minScale, _maxScale);
  }

  /// Converts a design-pixel measurement into logical pixels.
  double s(double designPx) => designPx * scale;

  /// Like [s], but picks a different design-pixel value per orientation
  /// first. [scale] itself is based on the device's *shortest* side, so it
  /// stays identical in portrait and landscape — meaning a plain [s] call
  /// renders pixel-identical in both, even though landscape has far less
  /// height to work with. Layouts that need to shrink specifically when
  /// height is scarce (the table screen's HUD, hand, and seat chrome) should
  /// use this instead of hand-rolling an `isPortrait ? … : …` check.
  double sc(double portraitPx, double landscapePx) =>
      s(isPortrait ? portraitPx : landscapePx);

  /// Wraps the nearest ancestor size. Falls back to the media query so widgets
  /// can be used in isolation (e.g. in tests).
  static Metrics of(BuildContext context) {
    final metrics = context.dependOnInheritedWidgetOfExactType<Metrics>();
    if (metrics != null) return metrics;
    return Metrics(size: MediaQuery.sizeOf(context), child: const SizedBox());
  }

  @override
  bool updateShouldNotify(Metrics oldWidget) =>
      oldWidget.size != size || oldWidget.scale != scale;
}

/// Installs [Metrics] from the screen size.
///
/// Sized from the media query rather than from the incoming layout
/// constraints on purpose: a `Scaffold` shrinks its body on every frame of the
/// on-screen keyboard's open/close animation ([Scaffold.resizeToAvoidBottomInset]),
/// but [MediaQuery.sizeOf] ignores that inset and keeps reporting the settled
/// screen. Keying the scale and the portrait/landscape split off the stable
/// value means `Metrics.updateShouldNotify` returns false while the keyboard
/// animates, so the whole subtree does not rebuild — and re-lay out — at 60fps
/// just to adjust to a shrinking viewport.
class MetricsScope extends StatelessWidget {
  const MetricsScope({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Metrics(
      size: MediaQuery.sizeOf(context),
      child: Builder(builder: builder),
    );
  }
}
