import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import 'backdrop.dart';
import 'buttons.dart';
import 'deadline_bar.dart';

/// Between-hands summary: what everyone bid and took this hand, what it was
/// worth, and the running totals — leader first, with a crown.
class Scoreboard extends StatelessWidget {
  const Scoreboard({
    super.key,
    required this.view,
    required this.onContinue,
    this.onRestart,
    this.deadline,
  });

  final GameView view;
  final VoidCallback onContinue;
  final VoidCallback? onRestart;

  /// When the table deals the next hand whether or not this player has
  /// tapped, so nobody is held up by a scoreboard left open. Null when the
  /// table is happy to wait — an offline game, or the final scoreboard.
  final DateTime? deadline;

  bool get _isFinal => view.phase == GamePhase.gameOver;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final placeOf = {for (final r in view.rankings) r.seat: r.place};
    final seats = [0, 1, 2, 3]
      ..sort((a, b) => view.totals[b].compareTo(view.totals[a]));

    return GlassPanel(
      padding: EdgeInsets.fromLTRB(
        m.sc(18, 14),
        m.sc(18, 12),
        m.sc(18, 14),
        m.sc(16, 10),
      ),
      // Sized to fit the overlay's budget; the scroll view is only a safety
      // net for the smallest landscape screens.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: GoldGradientText(
                _isFinal
                    ? 'Game over'
                    : 'Round ${view.handNumber} of ${view.handsPerGame}',
                style: AppText.wordmark(m.sc(21, 16)),
              ),
            ),
            Center(
              child: Text(
                _isFinal ? 'Final standings' : 'Round results',
                style: AppText.medium(m.sc(12, 10), AppColors.textFaint),
              ),
            ),
            SizedBox(height: m.sc(14, 8)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: m.sc(12, 10)),
              child: Row(
                children: [
                  Expanded(child: _HeaderText('Player', align: TextAlign.left)),
                  SizedBox(
                    width: m.sc(52, 46),
                    child: const _HeaderText('Bid/Won'),
                  ),
                  SizedBox(
                    width: m.sc(50, 44),
                    child: const _HeaderText('Round'),
                  ),
                  SizedBox(
                    width: m.sc(52, 46),
                    child: const _HeaderText('Total', align: TextAlign.right),
                  ),
                ],
              ),
            ),
            SizedBox(height: m.sc(6, 4)),
            for (var i = 0; i < seats.length; i++) ...[
              _ScoreRow(
                index: i,
                name: view.players[seats[i]].name,
                initial: view.players[seats[i]].initial,
                isYou: seats[i] == view.you,
                leader: i == 0 && view.totals[seats[0]] > view.totals[seats[1]],
                bid: view.bids[seats[i]],
                won: view.tricksWon[seats[i]],
                delta: view.roundScores[seats[i]].isEmpty
                    ? null
                    : view.roundScores[seats[i]].last,
                total: view.totals[seats[i]],
                place: _isFinal ? placeOf[seats[i]] : null,
              ),
              SizedBox(height: m.sc(6, 4)),
            ],
            SizedBox(height: m.sc(10, 6)),
            // Networked tables deal the next hand on their own once the
            // deadline runs out, so the button only shows where nobody is
            // timing the wait.
            if (deadline == null || _isFinal)
              GoldButton(
                label: _isFinal ? 'Play again' : 'Next round',
                icon: _isFinal
                    ? Icons.replay_rounded
                    : Icons.arrow_forward_rounded,
                dense: !m.isPortrait,
                onTap: _isFinal ? (onRestart ?? onContinue) : onContinue,
              ),
            if (!_isFinal && deadline != null) ...[
              SizedBox(height: m.sc(6, 4)),
              DeadlineBar(deadline: deadline, label: 'Next round'),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  const _HeaderText(this.text, {this.align = TextAlign.center});

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return Text(
      text.toUpperCase(),
      textAlign: align,
      style: AppText.semiBold(
        m.sc(9.5, 8.5),
        AppColors.textFaint,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({
    required this.index,
    required this.name,
    required this.initial,
    required this.isYou,
    required this.leader,
    required this.bid,
    required this.won,
    required this.delta,
    required this.total,
    required this.place,
  });

  final int index;
  final String name;
  final String initial;
  final bool isYou;
  final bool leader;
  final int? bid;
  final int won;
  final double? delta;
  final double total;
  final int? place;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final made = bid != null && won >= bid!;
    final d = delta;

    // Rows slide in one after another.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + 70 * index),
      curve: Motion.enter,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(0, m.s(10) * (1 - t)),
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
      ),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.sc(12, 10),
          vertical: m.sc(9, 6),
        ),
        decoration: BoxDecoration(
          color: isYou
              ? AppColors.gold.withValues(alpha: 0.1)
              : const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(m.sc(12, 10)),
          border: Border.all(
            color: leader
                ? AppColors.goldBorder.withValues(alpha: 0.6)
                : AppColors.hairline,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: m.sc(28, 22),
              height: m.sc(28, 22),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isYou ? goldButtonGradient : null,
                color: isYou ? null : const Color(0x26FFFFFF),
              ),
              child: Text(
                initial,
                style: AppText.bold(
                  m.sc(12, 10),
                  isYou ? AppColors.onGold : AppColors.textOnDark,
                ),
              ),
            ),
            SizedBox(width: m.sc(9, 7)),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.semiBold(
                        m.sc(13.5, 12),
                        AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (leader) ...[
                    SizedBox(width: m.s(4)),
                    Icon(
                      Icons.emoji_events_rounded,
                      size: m.sc(15, 13),
                      color: AppColors.gold,
                    ),
                  ],
                  if (place != null) ...[
                    SizedBox(width: m.s(4)),
                    Text(
                      const {1: '1st', 2: '2nd', 3: '3rd', 4: '4th'}[place] ??
                          '$place',
                      style: AppText.bold(m.sc(11, 10), AppColors.gold),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: m.sc(52, 46),
              child: Text(
                bid == null ? '–' : '$bid / $won',
                textAlign: TextAlign.center,
                style: AppText.semiBold(
                  m.sc(12, 11),
                  made ? AppColors.success : AppColors.textMuted,
                ),
              ),
            ),
            SizedBox(
              width: m.sc(50, 44),
              child: d == null
                  ? const SizedBox.shrink()
                  : Text(
                      '${d > 0 ? '+' : ''}${d.toStringAsFixed(1)}',
                      textAlign: TextAlign.center,
                      style: AppText.bold(
                        m.sc(12.5, 11),
                        d < 0 ? AppColors.danger : AppColors.success,
                      ),
                    ),
            ),
            SizedBox(
              width: m.sc(52, 46),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: total - (d ?? 0), end: total),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => Text(
                  value.toStringAsFixed(1),
                  textAlign: TextAlign.right,
                  style: AppText.bold(m.sc(16, 13.5), AppColors.gold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
