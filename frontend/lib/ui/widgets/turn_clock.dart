import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../../audio/audio_controller.dart';
import '../../design/tokens.dart';

/// The last stretch of a turn, drawn as a draining ring around a seat's avatar.
///
/// It deliberately says nothing for most of a turn. A clock that is always
/// visible stops being read; one that appears only when time is genuinely
/// short is impossible to ignore, which is the entire point — past the deadline
/// the table stops waiting and plays the seat automatically.
///
/// The ring drains over [_window] rather than over the turn's full length, so
/// it needs no agreement with the server about how long a turn is. Whatever the
/// server's timeout, the last ten seconds look the same.
class TurnClock extends StatefulWidget {
  const TurnClock({
    super.key,
    required this.deadline,
    required this.diameter,
    required this.audible,
  });

  /// When this turn runs out, measured on *this device's* clock — see
  /// [GameSession.turnDeadline], which does the conversion from server time.
  final DateTime deadline;

  /// Outer diameter of the ring; match the avatar's own turn ring.
  final double diameter;

  /// Whether this clock may tick out loud. Only the viewer's own clock does:
  /// ticking through somebody else's turn would be noise rather than urgency.
  final bool audible;

  @override
  State<TurnClock> createState() => _TurnClockState();
}

class _TurnClockState extends State<TurnClock> with SingleTickerProviderStateMixin {
  /// How much of a turn the ring covers. Longer and it becomes wallpaper.
  static const _window = Duration(seconds: 10);

  /// Below this the clock turns red, pulses, and starts ticking.
  static const _alarmSeconds = 5;

  /// A bare frame pump — the ring is driven by the wall clock, not by this
  /// controller's value, so that a dropped frame or a rebuild can never make it
  /// disagree with the actual deadline.
  late final AnimationController _frames = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  /// Whether the ticking loop is currently sounding for this clock.
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    _frames.addListener(_maybeTick);
  }

  @override
  void didUpdateWidget(TurnClock old) {
    super.didUpdateWidget(old);
    // A new deadline is a new turn; its clock starts silent and decides for
    // itself whether to tick again.
    if (old.deadline != widget.deadline) _setTicking(false);
  }

  @override
  void dispose() {
    _setTicking(false);
    _frames.dispose();
    super.dispose();
  }

  Duration get _remaining {
    // `clock` rather than DateTime.now() so a test can wind the turn forward
    // instead of sitting through it. In production the two are the same call.
    final left = widget.deadline.difference(clock.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Keeps the ticking loop in step with the countdown: silent outside the
  /// alarm window, one continuous run of it inside.
  void _maybeTick() {
    final seconds = (_remaining.inMilliseconds / 1000).ceil();
    final inAlarm = widget.audible && seconds > 0 && seconds <= _alarmSeconds;
    if (inAlarm) {
      if (!_ticking) _setTicking(true);
    } else {
      if (_ticking) _setTicking(false);
    }
  }

  void _setTicking(bool on) {
    if (_ticking == on) return;
    _ticking = on;
    final audio = AudioController.instance;
    if (on) {
      audio?.startTick();
    } else {
      audio?.stopTick();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _frames,
      builder: (context, _) {
        final left = _remaining;
        // Nothing to say outside the window, and nothing left to say once the
        // clock is spent — by then the server has taken the seat over and the
        // autoplay banner is the thing to read.
        if (left >= _window || left <= Duration.zero) {
          return const SizedBox.shrink();
        }

        final fraction = (left.inMilliseconds / _window.inMilliseconds).clamp(0.0, 1.0);
        final seconds = (left.inMilliseconds / 1000).ceil();
        final alarm = seconds <= _alarmSeconds;

        // Warm gold through the first half, red by the time it matters. The
        // colour carries the warning on its own, for anyone who cannot hear the
        // tick or has sound off.
        final urgency = (1 - fraction / 0.6).clamp(0.0, 1.0);
        final colour = Color.lerp(AppColors.goldMid, AppColors.danger, urgency)!;

        // A heartbeat under the alarm threshold, driven by the same wall clock
        // so it beats in step with the ticking rather than drifting against it.
        final beat = alarm
            ? 1 + 0.06 * math.sin(left.inMilliseconds / 1000 * 2 * math.pi)
            : 1.0;

        return SizedBox(
          width: widget.diameter,
          height: widget.diameter,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Transform.scale(
                scale: beat,
                child: CustomPaint(
                  size: Size.square(widget.diameter),
                  painter: _ClockRingPainter(
                    fraction: fraction,
                    colour: colour,
                    stroke: widget.diameter * 0.075,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.topLeft,
                child: _SecondsBadge(
                  seconds: seconds,
                  colour: colour,
                  size: widget.diameter * 0.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The draining arc: a full circle at the top of the window, gone at zero.
class _ClockRingPainter extends CustomPainter {
  const _ClockRingPainter({
    required this.fraction,
    required this.colour,
    required this.stroke,
  });

  final double fraction;
  final Color colour;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    const from = -math.pi / 2; // twelve o'clock
    final sweep = 2 * math.pi * fraction;

    // The track keeps the ring's shape legible once the arc has drained away,
    // so a seat about to time out still reads as a seat rather than a gap.
    canvas.drawCircle(
      rect.center,
      rect.width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0x66000000),
    );

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = colour;

    // Glow first, so the sharp arc sits on top of its own halo.
    canvas.drawArc(
      rect,
      from,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = colour.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke),
    );
    canvas.drawArc(rect, from, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_ClockRingPainter old) =>
      old.fraction != fraction || old.colour != colour || old.stroke != stroke;
}

/// The number of seconds left, for players who want the count rather than the
/// shape of it.
class _SecondsBadge extends StatelessWidget {
  const _SecondsBadge({required this.seconds, required this.colour, required this.size});

  final int seconds;
  final Color colour;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xE60A1207),
        border: Border.all(color: colour, width: size * 0.07),
      ),
      child: Text('$seconds', style: AppText.bold(size * 0.55, colour)),
    );
  }
}
