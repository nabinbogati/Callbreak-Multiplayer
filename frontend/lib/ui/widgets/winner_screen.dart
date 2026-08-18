import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import 'backdrop.dart';
import 'round_history.dart';

/// The final-game screen: podium standings, the full round history, and the
/// player's next move — another game or back to the lobby.
///
/// Rendered full-screen (not inside the table's usual card-sized `_Overlay`,
/// which is too narrow for a podium) once [GameView.phase] reaches
/// [GamePhase.gameOver].
class WinnerScreen extends StatefulWidget {
  const WinnerScreen({
    super.key,
    required this.view,
    required this.onPlayAgain,
    required this.onHome,
  });

  final GameView view;
  final VoidCallback onPlayAgain;
  final VoidCallback onHome;

  @override
  State<WinnerScreen> createState() => _WinnerScreenState();
}

class _WinnerScreenState extends State<WinnerScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
      ..forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final view = widget.view;
    final ranked = [...view.rankings]..sort((a, b) => a.place.compareTo(b.place));

    return Positioned.fill(
      child: Container(
        color: const Color(0xF004120D),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(m.s(20), m.sc(24, 14), m.s(20), m.s(20)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FadeTransition(
                  opacity: _entrance,
                  child: Center(
                    child: GoldGradientText(
                      'Game over',
                      style: AppText.wordmark(m.sc(24, 20)),
                    ),
                  ),
                ),
                SizedBox(height: m.sc(4, 2)),
                if (ranked.isNotEmpty)
                  Center(
                    child: Text(
                      '${view.players[ranked.first.seat].name} wins',
                      style: AppText.medium(m.sc(13, 11), AppColors.textFaint),
                    ),
                  ),
                SizedBox(height: m.sc(26, 14)),
                if (ranked.length == 4) _Podium(view: view, ranked: ranked, entrance: _entrance),
                SizedBox(height: m.sc(26, 16)),
                _HistoryCard(view: view),
                SizedBox(height: m.sc(22, 14)),
                _Actions(onPlayAgain: widget.onPlayAgain, onHome: widget.onHome),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rank-ordered podium: 1st stands tallest and centre-most, 2nd and 3rd flank
/// it, and 4th sits apart, lowest and smallest — a hierarchy readable at a
/// glance without needing the place tag underneath it.
class _Podium extends StatelessWidget {
  const _Podium({required this.view, required this.ranked, required this.entrance});

  final GameView view;
  final List<SeatRanking> ranked;
  final Animation<double> entrance;

  // Visual left-to-right order: 2nd, 1st, 3rd, 4th.
  static const _visualOrder = [1, 0, 2, 3];
  static const _pedestalHeights = [96.0, 66.0, 52.0, 40.0];
  static const _avatarSizes = [82.0, 68.0, 64.0, 58.0];
  static const _staggerStarts = [0.15, 0.0, 0.25, 0.35];

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final rankIndex in _visualOrder) ...[
          _PodiumColumn(
            ranking: ranked[rankIndex],
            player: view.players[ranked[rankIndex].seat],
            isYou: ranked[rankIndex].seat == view.you,
            pedestalHeight: m.s(_pedestalHeights[rankIndex]),
            avatarSize: m.s(_avatarSizes[rankIndex]),
            entrance: CurvedAnimation(
              parent: entrance,
              curve: Interval(
                _staggerStarts[rankIndex],
                (_staggerStarts[rankIndex] + 0.6).clamp(0.0, 1.0),
                curve: Curves.easeOutCubic,
              ),
            ),
          ),
          if (rankIndex != _visualOrder.last) SizedBox(width: m.sc(10, 6)),
        ],
      ],
    );
  }
}

class _PodiumColumn extends StatelessWidget {
  const _PodiumColumn({
    required this.ranking,
    required this.player,
    required this.isYou,
    required this.pedestalHeight,
    required this.avatarSize,
    required this.entrance,
  });

  final SeatRanking ranking;
  final PlayerInfo player;
  final bool isYou;
  final double pedestalHeight;
  final double avatarSize;
  final Animation<double> entrance;

  static const _placeLabel = {1: '1st', 2: '2nd', 3: '3rd', 4: '4th'};
  static const _pedestalColors = {
    1: [AppColors.gold, AppColors.goldDeep],
    2: [Color(0xFFDCE3EA), Color(0xFF97A3B0)],
    3: [Color(0xFFD8996A), Color(0xFF8C5A34)],
    4: [Color(0xFF3B4A44), Color(0xFF1D2622)],
  };

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final colors = _pedestalColors[ranking.place]!;

    final avatar = Container(
      width: avatarSize,
      height: avatarSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isYou ? const [AppColors.gold, AppColors.goldDeep] : colors,
        ),
        border: Border.all(
          color: isYou
              ? AppColors.goldLight.withValues(alpha: 0.9)
              : AppColors.textMuted.withValues(alpha: 0.3),
          width: isYou ? 2 : 1.5,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x73000000), blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: player.isBot
          ? Icon(Icons.smart_toy_outlined, size: avatarSize * 0.42, color: AppColors.textOnDark)
          : Text(
              player.initial,
              style: AppText.bold(
                avatarSize * 0.37,
                isYou ? AppColors.onGold : AppColors.textOnDark,
              ),
            ),
    );

    return FadeTransition(
      opacity: entrance,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(entrance),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ranking.place == 1 ? _GlowRing(size: avatarSize, child: avatar) : avatar,
            SizedBox(height: m.sc(8, 5)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.s(76)),
              child: Text(
                player.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.semiBold(m.sc(12, 11), AppColors.textPrimary),
              ),
            ),
            SizedBox(height: m.sc(2, 1)),
            Text(
              ranking.total.toStringAsFixed(1),
              style: AppText.bold(m.sc(12, 11), AppColors.gold),
            ),
            SizedBox(height: m.sc(8, 5)),
            Container(
              width: m.s(64),
              height: pedestalHeight,
              alignment: Alignment.topCenter,
              padding: EdgeInsets.only(top: m.sc(8, 6)),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: colors,
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(m.s(8))),
              ),
              child: Text(
                _placeLabel[ranking.place] ?? '${ranking.place}',
                style: AppText.bold(
                  m.sc(14, 12),
                  ranking.place <= 2 ? AppColors.onGold : AppColors.textOnDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A restrained, looping halo behind the winner's avatar — the "subtle
/// winner animation": a slow breathing glow, not confetti or a burst.
class _GlowRing extends StatefulWidget {
  const _GlowRing({required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  State<_GlowRing> createState() => _GlowRingState();
}

class _GlowRingState extends State<_GlowRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.gold.withValues(alpha: 0.16 + 0.14 * t),
                blurRadius: widget.size * 0.3 + 8 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.view});

  final GameView view;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.fromLTRB(m.s(18), m.s(14), m.s(18), m.s(16)),
      decoration: BoxDecoration(
        color: const Color(0xE604120D),
        borderRadius: BorderRadius.circular(m.s(16)),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Round history', style: AppText.bold(m.s(15), AppColors.textPrimary)),
          SizedBox(height: m.s(8)),
          SizedBox(height: m.sc(220, 160), child: RoundHistoryTable(view: view)),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.onPlayAgain, required this.onHome});

  final VoidCallback onPlayAgain;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      children: [
        Expanded(
          child: PressFeedback(
            onTap: onHome,
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(vertical: m.sc(14, 10)),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.textMuted.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(m.sc(14, 12)),
              ),
              child: Text('Home', style: AppText.bold(m.sc(14, 13), AppColors.textMuted)),
            ),
          ),
        ),
        SizedBox(width: m.s(12)),
        Expanded(
          child: PressFeedback(
            onTap: onPlayAgain,
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(vertical: m.sc(14, 10)),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [AppColors.gold, AppColors.goldDeep]),
                borderRadius: BorderRadius.circular(m.sc(14, 12)),
              ),
              child: Text('Play again', style: AppText.bold(m.sc(14, 13), AppColors.onGold)),
            ),
          ),
        ),
      ],
    );
  }
}
