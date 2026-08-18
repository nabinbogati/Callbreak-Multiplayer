import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/rules.dart';
import 'backdrop.dart';
import 'deadline_bar.dart';

/// The bidding sheet: pick how many tricks you'll take this hand, 1–13.
///
/// [hand] drives the suggested starting bid (see [suggestBid]); the player can
/// then nudge it up or down before confirming.
class BidPanel extends StatefulWidget {
  const BidPanel({
    super.key,
    required this.hand,
    required this.onBid,
    this.deadline,
  });

  final List<PlayingCard> hand;
  final ValueChanged<int> onBid;

  /// When the table bids for this seat and moves on, at a table where other
  /// people are waiting. Null at a table that can afford to wait — a solo game
  /// against bots — where the panel simply stays up.
  final DateTime? deadline;

  @override
  State<BidPanel> createState() => _BidPanelState();
}

class _BidPanelState extends State<BidPanel> {
  late int _value;
  late final int _suggested;

  @override
  void initState() {
    super.initState();
    _suggested = suggestBid(widget.hand);
    _value = _suggested;
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.fromLTRB(m.s(20), m.s(18), m.s(20), m.s(20)),
      decoration: BoxDecoration(
        color: const Color(0xE604120D),
        borderRadius: BorderRadius.circular(m.s(18)),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.35)),
        boxShadow: const [
          BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 12)),
        ],
      ),
      // Scrollable defensively, same reasoning as Scoreboard: _Overlay's
      // height budget can be as little as ~300px in landscape on a small
      // device, and this content is close enough to that limit that it's
      // safer to scroll than risk an overflow.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StepButton(
                  isPlus: false,
                  onTap: _value > minBid ? () => setState(() => _value--) : null,
                ),
                SizedBox(
                  width: m.s(48),
                  child: Center(
                    child: GoldGradientText('$_value', style: AppText.wordmark(m.s(34))),
                  ),
                ),
                _StepButton(
                  isPlus: true,
                  onTap: _value < maxBid ? () => setState(() => _value++) : null,
                ),
              ],
            ),
            SizedBox(height: m.s(12)),
            // The engine's estimate for this hand. Tapping it snaps the
            // stepper back to the suggestion.
            PressFeedback(
              onTap: _value == _suggested
                  ? null
                  : () => setState(() => _value = _suggested),
              scale: 0.96,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: m.s(14), vertical: m.s(7)),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(m.s(12)),
                  border: Border.all(
                    color: _value == _suggested
                        ? AppColors.goldBorder.withValues(alpha: 0.5)
                        : AppColors.hairline,
                  ),
                ),
                child: Text(
                  _value == _suggested
                      ? 'Suggested: $_suggested'
                      : 'Suggested: $_suggested · tap to use',
                  style: AppText.medium(
                    m.s(12),
                    _value == _suggested ? AppColors.gold : AppColors.textMuted,
                  ),
                ),
              ),
            ),
            SizedBox(height: m.s(18)),
            SizedBox(
              width: double.infinity,
              child: PressFeedback(
                onTap: () => widget.onBid(_value),
                child: Container(
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(vertical: m.s(14)),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppColors.gold, AppColors.goldDeep],
                    ),
                    borderRadius: BorderRadius.circular(m.s(14)),
                  ),
                  child: Text(
                    'Confirm bid',
                    style: AppText.bold(m.s(14), AppColors.onGold),
                  ),
                ),
              ),
            ),
            if (widget.deadline != null) ...[
              SizedBox(height: m.s(12)),
              DeadlineBar(deadline: widget.deadline, label: 'Bidding for you'),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.isPlus, required this.onTap});

  /// Drawn as bars rather than a '+'/'–' glyph on purpose: text sits on the
  /// font's baseline and the math axis is well below the line box's centre,
  /// so even a centred, even-leading `Text` renders visibly low in the
  /// circle. Two bars in a centred stack are exact at any scale.
  final bool isPlus;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final enabled = onTap != null;

    return PressFeedback(
      onTap: onTap,
      scale: 0.86,
      child: Container(
        width: m.s(44),
        height: m.s(44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.panel,
          border: Border.all(
            color: enabled
                ? AppColors.goldBorder.withValues(alpha: 0.6)
                : AppColors.hairline,
          ),
        ),
        child: _StepGlyph(
          isPlus: isPlus,
          color: enabled ? AppColors.gold : AppColors.textFaint,
        ),
      ),
    );
  }
}

/// A '+' or '–' built from bars so it centres on geometry, not font metrics.
class _StepGlyph extends StatelessWidget {
  const _StepGlyph({required this.isPlus, required this.color});

  final bool isPlus;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final length = m.s(17);
    final thickness = m.s(2.5);
    final bar = BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(thickness / 2),
    );

    return SizedBox(
      width: length,
      height: length,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: length, height: thickness, decoration: bar),
          if (isPlus) Container(width: thickness, height: length, decoration: bar),
        ],
      ),
    );
  }
}
