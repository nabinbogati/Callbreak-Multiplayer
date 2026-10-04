import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import 'backdrop.dart';
import 'buttons.dart';
import 'round_history.dart';

/// The final-game screen: a burst of confetti, the podium, the full round
/// history, and the player's next move — another game or back home.
///
/// Rendered full-screen once [GameView.phase] reaches [GamePhase.gameOver].
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

class _WinnerScreenState extends State<WinnerScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  /// One burst, then still — a celebration, not a screensaver.
  late final AnimationController _confetti = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..forward();

  @override
  void dispose() {
    _entrance.dispose();
    _confetti.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final view = widget.view;
    final ranked = [...view.rankings]
      ..sort((a, b) => a.place.compareTo(b.place));
    final youWon = ranked.isNotEmpty && ranked.first.seat == view.you;
    final headline = ranked.isEmpty
        ? 'Game over'
        : youWon
        ? 'You win!'
        : '${view.players[ranked.first.seat].name} wins';

    return Positioned.fill(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.6),
            radius: 1.2,
            colors: [Color(0xF2163A2C), Color(0xF8040F0B)],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _confetti,
                    builder: (context, _) => _confetti.isAnimating
                        ? CustomPaint(
                            painter: _ConfettiPainter(_confetti.value),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: m.s(560)),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      m.s(20),
                      m.sc(20, 12),
                      m.s(20),
                      m.s(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Trophy(entrance: _entrance, size: m.sc(64, 44)),
                        SizedBox(height: m.sc(10, 6)),
                        FadeTransition(
                          opacity: _entrance,
                          child: Center(
                            child: GoldGradientText(
                              headline,
                              style: AppText.wordmark(m.sc(28, 22)),
                            ),
                          ),
                        ),
                        Center(
                          child: Text(
                            'Game over · ${view.handsPerGame} rounds played',
                            style: AppText.medium(
                              m.sc(12, 11),
                              AppColors.textFaint,
                            ),
                          ),
                        ),
                        SizedBox(height: m.sc(22, 12)),
                        if (ranked.length == 4)
                          _Podium(
                            view: view,
                            ranked: ranked,
                            entrance: _entrance,
                          ),
                        SizedBox(height: m.sc(22, 14)),
                        _HistoryCard(view: view),
                        SizedBox(height: m.sc(18, 12)),
                        Row(
                          children: [
                            Expanded(
                              child: GhostButton(
                                label: 'Home',
                                icon: Icons.home_rounded,
                                onTap: widget.onHome,
                              ),
                            ),
                            SizedBox(width: m.s(12)),
                            Expanded(
                              child: GoldButton(
                                label: 'Play again',
                                icon: Icons.replay_rounded,
                                onTap: widget.onPlayAgain,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Trophy extends StatelessWidget {
  const _Trophy({required this.entrance, required this.size});

  final Animation<double> entrance;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: entrance,
      builder: (context, child) {
        final t = Curves.elasticOut.transform(
          const Interval(0, 0.9).transform(entrance.value),
        );
        return Transform.scale(scale: 0.4 + 0.6 * t, child: child);
      },
      child: Center(
        child: Container(
          width: size * 1.5,
          height: size * 1.5,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                AppColors.gold.withValues(alpha: 0.35),
                AppColors.gold.withValues(alpha: 0.0),
              ],
            ),
          ),
          child: Icon(
            Icons.emoji_events_rounded,
            size: size,
            color: AppColors.gold,
          ),
        ),
      ),
    );
  }
}

/// Rank-ordered podium: 1st tallest and centre, 2nd and 3rd flanking it, 4th
/// apart and lowest.
class _Podium extends StatelessWidget {
  const _Podium({
    required this.view,
    required this.ranked,
    required this.entrance,
  });

  final GameView view;
  final List<SeatRanking> ranked;
  final Animation<double> entrance;

  // Visual left-to-right order: 2nd, 1st, 3rd, 4th.
  static const _visualOrder = [1, 0, 2, 3];
  static const _pedestalHeights = [100.0, 70.0, 54.0, 40.0];
  static const _avatarSizes = [76.0, 62.0, 58.0, 52.0];
  static const _staggerStarts = [0.2, 0.05, 0.3, 0.4];

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
            pedestalHeight: m.sc(
              _pedestalHeights[rankIndex],
              _pedestalHeights[rankIndex] * 0.7,
            ),
            avatarSize: m.sc(
              _avatarSizes[rankIndex],
              _avatarSizes[rankIndex] * 0.8,
            ),
            entrance: CurvedAnimation(
              parent: entrance,
              curve: Interval(
                _staggerStarts[rankIndex],
                (_staggerStarts[rankIndex] + 0.55).clamp(0.0, 1.0),
                curve: Curves.easeOutBack,
              ),
            ),
          ),
          if (rankIndex != _visualOrder.last) SizedBox(width: m.sc(10, 8)),
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
    1: [Color(0xFFFFE7A3), AppColors.goldMid, AppColors.goldDeep],
    2: [Color(0xFFF2F5F8), Color(0xFFC3CCD6), Color(0xFF8995A2)],
    3: [Color(0xFFF0B78C), Color(0xFFC98552), Color(0xFF8C5A34)],
    4: [Color(0xFF52625B), Color(0xFF34413B), Color(0xFF1D2622)],
  };

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final colors = _pedestalColors[ranking.place]!;
    final first = ranking.place == 1;

    final avatar = Container(
      width: avatarSize,
      height: avatarSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isYou
              ? const [
                  AppColors.goldLight,
                  AppColors.goldMid,
                  AppColors.goldDeep,
                ]
              : colors,
        ),
        border: Border.all(
          color: first || isYou
              ? AppColors.goldLight.withValues(alpha: 0.95)
              : AppColors.textMuted.withValues(alpha: 0.35),
          width: first ? 2.5 : 1.5,
        ),
        boxShadow: first
            ? AppShadows.glow(AppColors.gold, strength: 1.2, blur: 22)
            : AppShadows.low,
      ),
      child: player.isBot
          ? Icon(
              Icons.smart_toy_outlined,
              size: avatarSize * 0.42,
              color: AppColors.onGold,
            )
          : Text(
              player.initial,
              style: AppText.bold(avatarSize * 0.4, AppColors.onGold),
            ),
    );

    return FadeTransition(
      opacity: entrance,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(entrance),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (first)
              Icon(
                Icons.workspace_premium_rounded,
                size: m.sc(22, 16),
                color: AppColors.gold,
              ),
            avatar,
            SizedBox(height: m.sc(8, 4)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.s(78)),
              child: Text(
                isYou ? 'You' : player.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.semiBold(m.sc(12, 11), AppColors.textPrimary),
              ),
            ),
            Text(
              ranking.total.toStringAsFixed(1),
              style: AppText.bold(m.sc(13, 11), AppColors.gold),
            ),
            SizedBox(height: m.sc(8, 4)),
            Container(
              width: m.s(68),
              height: pedestalHeight,
              alignment: Alignment.topCenter,
              padding: EdgeInsets.only(top: m.sc(8, 5)),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: colors,
                ),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(m.s(10)),
                ),
                boxShadow: AppShadows.low,
              ),
              child: Text(
                _placeLabel[ranking.place] ?? '${ranking.place}',
                style: AppText.bold(
                  m.sc(15, 12),
                  ranking.place <= 3 ? AppColors.onGold : AppColors.textOnDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.view});

  final GameView view;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPanel(
      padding: EdgeInsets.fromLTRB(m.s(16), m.s(14), m.s(16), m.s(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.leaderboard_rounded,
                size: m.s(16),
                color: AppColors.gold,
              ),
              SizedBox(width: m.s(8)),
              Text(
                'Round history',
                style: AppText.bold(m.s(15), AppColors.textPrimary),
              ),
            ],
          ),
          SizedBox(height: m.s(6)),
          SizedBox(
            height: m.sc(210, 150),
            child: RoundHistoryTable(view: view),
          ),
        ],
      ),
    );
  }
}

/// A single burst of paper: pieces launched from the top, fluttering down
/// with a sway and a spin. Positions are a pure function of time and a fixed
/// seed, so the painter holds no state and one controller drives it all.
class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t);

  final double t;

  static const _count = 70;
  static const _colors = [
    AppColors.gold,
    AppColors.goldLight,
    Color(0xFF3DDC84),
    Color(0xFF7CC4FF),
    Color(0xFFFF6F61),
    Color(0xFFE8B84A),
  ];

  static final List<_Piece> _pieces = () {
    final r = math.Random(42);
    return [
      for (var i = 0; i < _count; i++)
        _Piece(
          x: r.nextDouble(),
          delay: r.nextDouble() * 0.35,
          fall: 0.75 + r.nextDouble() * 0.5,
          sway: 0.02 + r.nextDouble() * 0.05,
          spin: (r.nextDouble() - 0.5) * 18,
          size: 5 + r.nextDouble() * 6,
          color: _colors[i % _colors.length],
        ),
    ];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in _pieces) {
      final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final y = -0.1 + Motion.enter.transform(local) * p.fall * 1.1;
      final x = p.x + math.sin(local * math.pi * 4 + p.x * 9) * p.sway;
      final fade = local > 0.75 ? (1 - local) / 0.25 : 1.0;
      paint.color = p.color.withValues(alpha: 0.9 * fade);
      canvas.save();
      canvas.translate(x * size.width, y * size.height);
      canvas.rotate(p.spin * local);
      // A tumbling rectangle reads as paper: squash it with the spin.
      final squash = 0.35 + 0.65 * math.cos(local * p.spin).abs();
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: p.size,
          height: p.size * 0.55 * squash,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

class _Piece {
  const _Piece({
    required this.x,
    required this.delay,
    required this.fall,
    required this.sway,
    required this.spin,
    required this.size,
    required this.color,
  });

  final double x;
  final double delay;
  final double fall;
  final double sway;
  final double spin;
  final double size;
  final Color color;
}
