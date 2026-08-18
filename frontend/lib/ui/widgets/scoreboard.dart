import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import 'backdrop.dart';
import 'deadline_bar.dart';

/// Between-hands and end-of-game summary: totals per seat, and a place badge
/// once the game has a final ranking.
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

  /// When the table deals the next hand whether or not this player has tapped,
  /// so nobody else is held up by a scoreboard left open. Null when the table
  /// is happy to wait — an offline game, or the final scoreboard, which nobody
  /// is dealt out of.
  final DateTime? deadline;

  bool get _isFinal => view.phase == GamePhase.gameOver;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final placeOf = {for (final r in view.rankings) r.seat: r.place};

    final seats = [0, 1, 2, 3]
      ..sort((a, b) => view.totals[b].compareTo(view.totals[a]));

    return Container(
      padding: EdgeInsets.fromLTRB(
        m.sc(22, 16),
        m.sc(20, 14),
        m.sc(22, 16),
        m.sc(18, 12),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF04120D),
        borderRadius: BorderRadius.circular(m.s(18)),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.35)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      // Scrollable as a safety net only: the sizing below is meant to let the
      // whole summary fit _Overlay's budget without touching it (landscape can
      // leave as little as ~300px of height), so on any real device the scroll
      // view never actually moves.
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
                style: AppText.wordmark(m.sc(20, 16)),
              ),
            ),
            SizedBox(height: m.sc(4, 2)),
            if (!_isFinal)
              Center(
                child: Text(
                  'Scores so far',
                  style: AppText.medium(m.sc(12, 10), AppColors.textFaint),
                ),
              ),
            SizedBox(height: m.sc(16, 8)),
            for (final seat in seats) ...[
              _ScoreRow(
                name: view.players[seat].name,
                total: view.totals[seat],
                place: _isFinal ? placeOf[seat] : null,
              ),
              SizedBox(height: m.sc(8, 6)),
            ],
            SizedBox(height: m.sc(10, 6)),
            // The table only waits here in an offline game, where nobody is on
            // the clock; networked tables deal the next hand on their own once
            // the deadline runs out, so that button is redundant there.
            if (deadline == null || _isFinal)
              SizedBox(
                width: double.infinity,
                child: PressFeedback(
                  onTap: _isFinal ? (onRestart ?? onContinue) : onContinue,
                  child: Container(
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(vertical: m.sc(14, 10)),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.gold, AppColors.goldDeep],
                      ),
                      borderRadius: BorderRadius.circular(m.sc(14, 12)),
                    ),
                    child: Text(
                      _isFinal ? 'Play again' : 'Next round',
                      style: AppText.bold(m.sc(14, 13), AppColors.onGold),
                    ),
                  ),
                ),
              ),
            if (!_isFinal && deadline != null) ...[
              SizedBox(height: m.sc(12, 8)),
              DeadlineBar(deadline: deadline, label: 'Next round'),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({
    required this.name,
    required this.total,
    required this.place,
  });

  final String name;
  final double total;
  final int? place;

  static const _medal = {1: '🥇', 2: '🥈', 3: '🥉', 4: '4th'};

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(14, 12),
        vertical: m.sc(10, 7),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0A2119),
        borderRadius: BorderRadius.circular(m.sc(11, 9)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        children: [
          if (place != null) ...[
            Text(
              _medal[place] ?? '$place',
              style: AppText.semiBold(m.sc(14, 12), AppColors.gold),
            ),
            SizedBox(width: m.sc(10, 8)),
          ],
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.semiBold(m.sc(14, 12), AppColors.textPrimary),
            ),
          ),
          Text(
            total.toStringAsFixed(1),
            style: AppText.bold(m.sc(16, 14), AppColors.gold),
          ),
        ],
      ),
    );
  }
}
