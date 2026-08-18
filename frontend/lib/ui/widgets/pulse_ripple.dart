import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';

/// Radar-style ripple around a centred glyph: rings that expand outwards and
/// fade, on a repeating loop. Communicates "searching / connecting / waiting"
/// far more explicitly than a bare spinner — the motion says the app is still
/// trying — and is deliberately gentle so it never competes with the table.
class PulseRipple extends StatefulWidget {
  const PulseRipple({
    super.key,
    required this.child,
    this.color = AppColors.gold,
    this.ringCount = 2,
    this.size,
    this.period = const Duration(milliseconds: 1700),
  });

  /// The glyph the rings expand around, centred within [size].
  final Widget child;

  /// Ring colour. Defaults to the brand gold.
  final Color color;

  /// How many expanding rings to show at once, staggered evenly around the
  /// loop. Two reads as a calm "still trying"; three as a busier "active".
  final int ringCount;

  /// Bounding box of the whole widget, rings included. Defaults to the child's
  /// own size plus two ring gaps.
  final double? size;

  /// One full launch-and-fade cycle of a single ring.
  final Duration period;

  @override
  State<PulseRipple> createState() => _PulseRippleState();
}

class _PulseRippleState extends State<PulseRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.period)
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    // Rings travel from the child's edge to the widget's edge, so the box
    // wants a couple of gaps of breathing room around the glyph.
    final size = widget.size ?? m.s(62);

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < widget.ringCount; i++)
                _Ring(
                  // A ring's phase is its own position around the loop; the
                  // stagger keeps the rings apart instead of stacking.
                  phase: (t + i / widget.ringCount) % 1.0,
                  size: size,
                  color: widget.color,
                ),
              widget.child,
            ],
          );
        },
      ),
    );
  }
}

/// One expanding ring at a given phase of the loop, painted as a bordered
/// circle that grows from the glyph's edge outward while fading out.
class _Ring extends StatelessWidget {
  const _Ring({
    required this.phase,
    required this.size,
    required this.color,
  });

  /// 0 = just launched at the glyph's edge, 1 = fully expanded and gone.
  final double phase;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // A ring starts tight around the glyph (full inset) and relaxes out to
    // the widget's edge (no inset), fading the whole way.
    final inset = size * 0.5 * (1.0 - phase);
    final alpha = (1.0 - phase) * 0.45;

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: color.withValues(alpha: alpha),
              width: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
