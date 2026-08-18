import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';

/// The three-stop gradient plus soft radial bloom that sits behind every
/// screen. Portrait runs the gradient top-to-bottom, landscape left-to-right,
/// exactly as the design specifies.
class Backdrop extends StatelessWidget {
  const Backdrop({
    super.key,
    required this.colors,
    required this.glow,
    required this.child,
    this.glowAlignment = const Alignment(-0.7, 0.1),
    this.glowScale = 1.1,
    this.horizontal = false,
  });

  final List<Color> colors;
  final Color glow;
  final Widget child;
  final Alignment glowAlignment;
  final double glowScale;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
          end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
          colors: colors,
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: glowAlignment,
            child: FractionallySizedBox(
              widthFactor: glowScale,
              heightFactor: glowScale,
              // A layered radial gradient, not a blurred circle. The blur this
              // replaced (an ImageFiltered gaussian across the whole screen)
              // re-rasterized the entire backdrop on every resize — each frame
              // of the keyboard opening, for instance — which is exactly what
              // made touching a text field feel sluggish. The extra stops
              // feather the same soft bloom at a fixed shader cost instead.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      glow.withValues(alpha: 0.42),
                      glow.withValues(alpha: 0.24),
                      glow.withValues(alpha: 0.11),
                      glow.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.4, 0.7, 1.0],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Text painted with the gold gradient used for the wordmark.
class GoldGradientText extends StatelessWidget {
  const GoldGradientText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => goldTextGradient.createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: style.copyWith(color: AppColors.goldLight),
      ),
    );
  }
}

/// Wraps a tappable so it visibly depresses while pressed — it scales down and
/// dims for the duration of the touch, then springs back on release. Bigger
/// controls can opt out of the shrink (or go deeper) with a [scale] of their
/// own. Inert when [onTap] is null, so decorative plates and badges never move.
class PressFeedback extends StatefulWidget {
  const PressFeedback({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.94,
  });

  final Widget child;

  /// Tap handler; null renders the child plain (no gesture, no movement).
  final VoidCallback? onTap;

  /// How far the child shrinks while held. Defaults to 0.94, the tactile
  /// push-down every control used to get; pass 1.0 for a dim-only press or a
  /// smaller value for a deeper one.
  final double scale;

  @override
  State<PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<PressFeedback> {
  bool _pressed = false;
  Offset? _downPosition;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;
    final shrinks = widget.scale < 1.0;
    Widget body = AnimatedOpacity(
      opacity: interactive && _pressed ? 0.82 : 1.0,
      duration: const Duration(milliseconds: 90),
      child: widget.child,
    );
    if (shrinks) {
      body = AnimatedScale(
        scale: interactive && _pressed ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutCubic,
        child: body,
      );
    }

    if (!interactive) return body;

    // The tap recognizer below only fires onTapDown once it has won the
    // gesture arena — inside a scrollable that is the moment the finger lifts,
    // so a quick tap would get no visual press at all. The raw Listener sees
    // the pointer the instant it goes down, so the press is always immediate;
    // the GestureDetector still owns the tap itself, and the press releases on
    // lift, cancel, or once the finger wanders past touch-slop (a scroll).
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _downPosition = event.position;
        _setPressed(true);
      },
      onPointerMove: (event) {
        final down = _downPosition;
        if (down != null && (event.position - down).distance > kTouchSlop) {
          _downPosition = null;
          _setPressed(false);
        }
      },
      onPointerUp: (_) {
        _downPosition = null;
        _setPressed(false);
      },
      onPointerCancel: (_) {
        _downPosition = null;
        _setPressed(false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: body,
      ),
    );
  }
}

/// The translucent dark chip used for HUD controls, seat plates and badges.
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.padding,
    this.radius = 12,
    this.background = AppColors.panelSoft,
    this.border = AppColors.hairline,
    this.borderWidth = 1,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Color background;
  final Color border;
  final double borderWidth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressFeedback(
      onTap: onTap,
      child: Container(
        padding:
            padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: border, width: borderWidth),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}
