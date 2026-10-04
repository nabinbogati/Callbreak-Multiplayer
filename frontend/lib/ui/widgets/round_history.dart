import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import 'backdrop.dart';
import 'buttons.dart';

/// Full round-by-round scorecard, opened by tapping the HUD's round pill.
///
/// Unlike the modal bidding/hand-over overlays, this one never blocks the
/// game underneath — tapping the scrim or the close button dismisses it and
/// play continues exactly where it left off.
class RoundHistoryOverlay extends StatelessWidget {
  const RoundHistoryOverlay({super.key, required this.view, required this.onClose});

  final GameView view;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: AppColors.scrim,
          alignment: Alignment.center,
          child: GestureDetector(
            // Absorb taps on the card itself so they don't fall through to
            // the scrim behind it and close the sheet.
            onTap: () {},
            behavior: HitTestBehavior.opaque,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.s(420), maxHeight: m.s(520)),
              child: Padding(
                padding: EdgeInsets.all(m.s(20)),
                child: PopIn(child: _Card(view: view, onClose: onClose)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.view, required this.onClose});

  final GameView view;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPanel(
      padding: EdgeInsets.fromLTRB(m.s(20), m.s(18), m.s(20), m.s(18)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.leaderboard_rounded, size: m.s(18), color: AppColors.gold),
              SizedBox(width: m.s(8)),
              Expanded(
                child: Text(
                  'Round history',
                  style: AppText.bold(m.s(17), AppColors.textPrimary),
                ),
              ),
              PressFeedback(
                onTap: onClose,
                scale: 0.9,
                child: Container(
                  padding: EdgeInsets.all(m.s(6)),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x14FFFFFF),
                    border: Border.all(color: AppColors.hairlineStrong),
                  ),
                  child: Icon(Icons.close_rounded, size: m.s(16), color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          SizedBox(height: m.s(4)),
          Flexible(child: RoundHistoryTable(view: view)),
        ],
      ),
    );
  }
}

/// The rounds/live score table on its own, without the card chrome or close
/// button — shared by [RoundHistoryOverlay] and the final-game winner screen.
class RoundHistoryTable extends StatelessWidget {
  const RoundHistoryTable({super.key, required this.view});

  final GameView view;

  @override
  Widget build(BuildContext context) {
    final rounds = view.roundScores.isEmpty ? 0 : view.roundScores[0].length;
    final hasLive = view.phase == GamePhase.bidding || view.phase == GamePhase.playing;

    if (rounds == 0 && !hasLive) return _EmptyState(view: view);
    return _ScoreTable(view: view, rounds: rounds, hasLive: hasLive);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.view});

  final GameView view;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: m.s(28)),
      child: Center(
        child: Text(
          'No rounds completed yet — check back after round 1.',
          textAlign: TextAlign.center,
          style: AppText.medium(m.s(13), AppColors.textFaint),
        ),
      ),
    );
  }
}

/// Paints one continuous, full-height band behind the [youIndex] column of a
/// grid laid out with a `2`-flex lead column and four `3`-flex seat columns
/// (the shared geometry of the round-history and game-scorecard tables).
///
/// A single [Stack] band reads as a real column instead of dashed per-row
/// swatches, and because it sits behind the scrolling rows it stays fixed and
/// uninterrupted however far the table scrolls. Pass a negative [youIndex]
/// (e.g. `-1`) to disable the highlight.
class YouColumnHighlight extends StatelessWidget {
  const YouColumnHighlight({
    super.key,
    required this.youIndex,
    required this.color,
    required this.child,
  });

  /// 0-based cell index of the column to highlight — 0 is the leading
  /// round/label column, 1..4 are the seats. Negative disables the highlight.
  final int youIndex;
  final Color color;
  final Widget child;

  static const _leadFlex = 2;
  static const _seatFlex = 3;

  @override
  Widget build(BuildContext context) {
    if (youIndex < 1) return child;
    final m = Metrics.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = _leadFlex + _seatFlex * 4;
        final left = (_leadFlex + _seatFlex * (youIndex - 1)) / total;
        final right = (_leadFlex + _seatFlex * youIndex) / total;
        return Stack(
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: constraints.maxWidth * left,
              width: constraints.maxWidth * (right - left),
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(m.s(6)),
                  ),
                ),
              ),
            ),
            child,
          ],
        );
      },
    );
  }
}

class _ScoreTable extends StatelessWidget {
  const _ScoreTable({required this.view, required this.rounds, required this.hasLive});

  final GameView view;
  final int rounds;

  /// Whether a hand is currently in progress (bidding or playing), so its
  /// live, not-yet-finalized state should be shown alongside the completed
  /// rounds below.
  final bool hasLive;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final seats = [0, 1, 2, 3];
    final you = view.you;
    final youIndex = you == null ? -1 : seats.indexOf(you) + 1;

    // A soft gold band standing behind the local player's whole column, so
    // their scores read at a glance even when two players share a name.
    return YouColumnHighlight(
      youIndex: youIndex,
      color: AppColors.gold.withValues(alpha: 0.08),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: m.s(10)),
          _Row(
            cells: ['Rnd', for (final seat in seats) view.players[seat].name],
            styleFor: (i) => AppText.semiBold(
              m.s(11),
              i > 0 && seats[i - 1] == you ? AppColors.gold : AppColors.textFaint,
            ),
            leadFlex: 2,
          ),
          SizedBox(height: m.s(6)),
          Container(height: 1, color: AppColors.hairline),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var round = 0; round < rounds; round++) ...[
                    SizedBox(height: m.s(8)),
                    _Row(
                      cells: [
                        '${round + 1}',
                        for (final seat in seats)
                          view.roundScores[seat][round].toStringAsFixed(1),
                      ],
                      styleFor: (i) => i == 0
                          ? AppText.medium(m.s(12), AppColors.textMuted)
                          : AppText.semiBold(
                              m.s(12),
                              _deltaColor(view.roundScores[i - 1][round]),
                            ),
                      leadFlex: 2,
                    ),
                  ],
                  if (hasLive) ...[
                    SizedBox(height: m.s(8)),
                    _LiveRoundRow(view: view),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: m.s(8)),
          Container(height: 1, color: AppColors.hairline),
          SizedBox(height: m.s(8)),
          _Row(
            cells: [
              'Total',
              for (final seat in seats) view.totals[seat].toStringAsFixed(1),
            ],
            styleFor: (i) => i == 0
                ? AppText.bold(m.s(12), AppColors.textPrimary)
                : AppText.bold(m.s(13), AppColors.gold),
            leadFlex: 2,
          ),
        ],
      ),
    );
  }

  static Color _deltaColor(double delta) {
    if (delta < 0) return AppColors.danger;
    if (delta > 0) return AppColors.gold;
    return AppColors.textMuted;
  }
}

/// The hand currently being bid/played, shown live beneath the finalized
/// historical rows — not yet a completed round, so it gets a distinct
/// gold-tinted treatment instead of the plain totals-row styling.
class _LiveRoundRow extends StatelessWidget {
  const _LiveRoundRow({required this.view});

  final GameView view;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final seats = [0, 1, 2, 3];

    return Container(
      padding: EdgeInsets.symmetric(horizontal: m.s(8), vertical: m.s(8)),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(m.s(8)),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
            Row(
              children: [
                Container(
                  width: m.s(6),
                  height: m.s(6),
                  margin: EdgeInsets.only(right: m.s(6)),
                  decoration: const BoxDecoration(
                    color: AppColors.gold,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(
                  'Round ${view.handNumber} — live',
                  style: AppText.bold(m.s(11), AppColors.gold),
                ),
              ],
            ),
            SizedBox(height: m.s(6)),
            _Row(
            cells: [
              '',
              for (final seat in seats)
                '${view.bids[seat]?.toString() ?? '–'} / ${view.tricksWon[seat]}',
            ],
            styleFor: (i) => i == 0
                ? AppText.medium(m.s(12), AppColors.textMuted)
                : AppText.semiBold(m.s(12), AppColors.textOnDark),
            leadFlex: 2,
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.cells,
    required this.styleFor,
    required this.leadFlex,
  });

  /// First entry is the leading (round/label) column; the rest are one per
  /// seat.
  final List<String> cells;
  final TextStyle Function(int index) styleFor;
  final int leadFlex;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: i == 0 ? leadFlex : 3,
            child: Text(
              cells[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: i == 0 ? TextAlign.left : TextAlign.center,
              style: styleFor(i),
            ),
          ),
      ],
    );
  }
}
