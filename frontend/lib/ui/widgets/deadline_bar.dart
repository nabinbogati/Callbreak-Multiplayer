import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';

/// A draining bar and a caption for a deadline the player is about to be
/// carried past: the bid they have not confirmed, the scoreboard nobody has
/// dismissed yet.
///
/// Unlike [TurnClock] on a seat, this shows for the whole wait rather than the
/// last few seconds. It is attached to a panel the player is being asked to
/// answer, and what it has to say — *this decision gets made with or without
/// you* — is worth knowing before the last second, not after it.
///
/// It only reports the clock; the table it belongs to is the thing that acts
/// on it. Nothing is sent from here, so a player who has stopped answering
/// still stops answering, and the host's own timeout is free to hand their
/// seat to a bot rather than being told they are still around.
class DeadlineBar extends StatefulWidget {
  const DeadlineBar({
    super.key,
    required this.deadline,
    required this.label,
  });

  /// When the table stops waiting, on this device's clock — see
  /// [GameSession.turnDeadline] and [GameSession.handAdvanceDeadline], which
  /// convert it from the host's. Null renders nothing at all, which is what an
  /// offline table (where nobody is kept waiting) wants.
  final DateTime? deadline;

  /// What happens at zero, phrased to be read before "in 7s": for instance
  /// 'Bidding for you'.
  final String label;

  @override
  State<DeadlineBar> createState() => _DeadlineBarState();
}

class _DeadlineBarState extends State<DeadlineBar>
    with SingleTickerProviderStateMixin {
  /// Below this the bar turns red — the same threshold the seat rings use, so
  /// "running out" looks the same wherever the player is looking.
  static const _alarmSeconds = 5;

  /// A bare frame pump. The bar is drawn from the wall clock rather than from
  /// this controller's value, so a dropped frame cannot make it disagree with
  /// the deadline it is drawing.
  late final AnimationController _frames = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  /// How long the wait was when this bar first saw it, which is what the bar
  /// drains against. Taken from the clock rather than passed in so the widget
  /// needs no agreement with the host about how long a turn is.
  Duration? _span;

  @override
  void didUpdateWidget(DeadlineBar old) {
    super.didUpdateWidget(old);
    // A new deadline is a new wait, drained from full again.
    if (old.deadline != widget.deadline) _span = null;
  }

  @override
  void dispose() {
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deadline = widget.deadline;
    if (deadline == null) return const SizedBox.shrink();
    final m = Metrics.of(context);

    return AnimatedBuilder(
      animation: _frames,
      builder: (context, _) {
        // `clock` rather than DateTime.now() so a test can wind the wait
        // forward instead of sitting through it.
        final raw = deadline.difference(clock.now());
        final left = raw.isNegative ? Duration.zero : raw;
        final span = _span ??= left;

        final fraction = span.inMilliseconds <= 0
            ? 0.0
            : (left.inMilliseconds / span.inMilliseconds).clamp(0.0, 1.0);
        final seconds = (left.inMilliseconds / 1000).ceil();
        final alarm = seconds <= _alarmSeconds;
        final colour = alarm ? AppColors.danger : AppColors.goldMid;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(m.s(2)),
              child: SizedBox(
                height: m.s(4),
                child: Stack(
                  children: [
                    Container(color: AppColors.hairline),
                    FractionallySizedBox(
                      widthFactor: fraction,
                      child: Container(color: colour),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: m.s(6)),
            Text(
              '${widget.label} in ${seconds}s',
              textAlign: TextAlign.center,
              style: AppText.medium(
                m.s(11),
                alarm ? AppColors.danger : AppColors.textFaint,
              ),
            ),
          ],
        );
      },
    );
  }
}
