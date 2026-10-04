import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/rules.dart';
import '../haptics.dart';
import 'backdrop.dart';
import 'buttons.dart';
import 'deadline_bar.dart';

/// The bidding sheet: how many tricks you'll take this hand, 1–13.
///
/// Every possible bid is on screen at once, so choosing is a single tap
/// rather than a walk up and down a stepper. [hand] drives the suggested bid
/// (see [suggestBid]), which starts selected and keeps a star so the player
/// can always find their way back to it.
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
  /// people are waiting. Null where the table can afford to wait (a solo game
  /// against bots), and the panel simply stays up.
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

  void _select(int value) {
    if (value == _value) return;
    Haptics.tick(context);
    setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final tall = m.isPortrait;

    return GlassPanel(
      padding: EdgeInsets.fromLTRB(
        m.s(18),
        m.sc(16, 12),
        m.s(18),
        m.sc(18, 12),
      ),
      // Scrollable defensively: a small landscape screen leaves little height.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Your bid',
                        style: AppText.bold(
                          m.sc(17, 15),
                          AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'How many tricks will you take?',
                        style: AppText.medium(
                          m.sc(11.5, 10.5),
                          AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                _BigValue(value: _value, size: m.sc(38, 30)),
              ],
            ),
            SizedBox(height: m.sc(14, 8)),
            LayoutBuilder(
              builder: (context, c) {
                const perRow = 7;
                final gap = m.sc(6, 5);
                final size = (c.maxWidth - gap * (perRow - 1)) / perRow;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  alignment: WrapAlignment.center,
                  children: [
                    for (var bid = minBid; bid <= maxBid; bid++)
                      _BidChip(
                        value: bid,
                        size: size,
                        height: tall ? size : size * 0.82,
                        selected: bid == _value,
                        suggested: bid == _suggested,
                        onTap: () => _select(bid),
                      ),
                  ],
                );
              },
            ),
            SizedBox(height: m.sc(10, 6)),
            // The engine's estimate, and a way back to it.
            Center(
              child: PressFeedback(
                onTap: _value == _suggested ? null : () => _select(_suggested),
                scale: 0.96,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: EdgeInsets.symmetric(
                    horizontal: m.s(12),
                    vertical: m.sc(6, 4),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.circular(m.s(12)),
                    border: Border.all(
                      color: _value == _suggested
                          ? AppColors.goldBorder.withValues(alpha: 0.5)
                          : AppColors.hairline,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: m.s(13),
                        color: AppColors.gold,
                      ),
                      SizedBox(width: m.s(6)),
                      Text(
                        _value == _suggested
                            ? 'Suggested: $_suggested'
                            : 'Suggested: $_suggested · tap to use',
                        style: AppText.medium(
                          m.sc(12, 11),
                          _value == _suggested
                              ? AppColors.gold
                              : AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: m.sc(14, 8)),
            GoldButton(
              label: 'Confirm bid',
              dense: !tall,
              onTap: () => widget.onBid(_value),
            ),
            if (widget.deadline != null) ...[
              SizedBox(height: m.sc(12, 8)),
              DeadlineBar(deadline: widget.deadline, label: 'Bidding for you'),
            ],
          ],
        ),
      ),
    );
  }
}

/// The chosen number, large, rolling to each new value.
class _BigValue extends StatelessWidget {
  const _BigValue({required this.value, required this.size});

  final int value;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.5,
      height: size * 1.25,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Motion.enter,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(
            scale: Tween(begin: 0.6, end: 1.0).animate(a),
            child: child,
          ),
        ),
        child: Center(
          key: ValueKey(value),
          child: GoldGradientText('$value', style: AppText.wordmark(size)),
        ),
      ),
    );
  }
}

class _BidChip extends StatelessWidget {
  const _BidChip({
    required this.value,
    required this.size,
    required this.height,
    required this.selected,
    required this.suggested,
    required this.onTap,
  });

  final int value;
  final double size;
  final double height;
  final bool selected;
  final bool suggested;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return PressFeedback(
      onTap: onTap,
      scale: 0.88,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Motion.emphasized,
        width: size,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: selected ? goldButtonGradient : null,
          color: selected ? null : const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(m.s(10)),
          border: Border.all(
            color: selected
                ? const Color(0x99FFF6D8)
                : suggested
                ? AppColors.goldBorder.withValues(alpha: 0.7)
                : AppColors.hairlineStrong,
            width: suggested && !selected ? 1.4 : 1,
          ),
          boxShadow: selected
              ? AppShadows.glow(AppColors.goldDeep, strength: 0.9, blur: 12)
              : null,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Text(
              '$value',
              style: AppText.bold(
                size * 0.4,
                selected ? AppColors.onGold : AppColors.textPrimary,
              ),
            ),
            if (suggested)
              Positioned(
                top: size * 0.06,
                right: size * 0.08,
                child: Icon(
                  Icons.star_rounded,
                  size: size * 0.26,
                  color: selected ? AppColors.onGold : AppColors.gold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
