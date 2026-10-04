import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import 'playing_card_view.dart';
import 'turn_clock.dart';

/// Where a seat sits on screen, relative to the viewer.
enum SeatSlot { bottom, left, top, right }

/// Maps an absolute seat index onto a screen position for the given viewer, so
/// whoever is looking always sees themselves at the bottom.
SeatSlot slotFor({required int seat, required int? viewer}) =>
    SeatSlot.values[(seat - (viewer ?? 0) + 4) % 4];

/// Avatar plus name and bid plates for one player around the table.
///
/// Also the place the table talks about a player: a ring that pings when
/// their turn comes, a speech bubble when they bid, and a "+1" that floats
/// off their score when they take a trick.
class SeatView extends StatefulWidget {
  const SeatView({
    super.key,
    required this.player,
    required this.slot,
    required this.palette,
    required this.bid,
    required this.tricksWon,
    required this.isTurn,
    required this.isDealer,
    this.isHost = false,
    this.deadline,
    this.handCount,
    this.axis,
  });

  final PlayerInfo player;
  final SeatSlot slot;
  final ThemePalette palette;
  final int? bid;
  final int tricksWon;
  final bool isTurn;
  final bool isDealer;

  /// Whether this seat runs the table (may start/restart it). Only networked
  /// tables have one — a solo game has no host, so this stays false.
  final bool isHost;

  /// When this seat's turn runs out, on the device's clock. Null unless the
  /// seat is on the clock and a real person is being waited for.
  final DateTime? deadline;

  /// How many cards this seat holds, for the face-down fan in front of an
  /// opponent's avatar. Null (and always for the bottom seat) renders none.
  final int? handCount;

  /// Lays the plates out beside the avatar (horizontal) or above and below it
  /// (vertical). Defaults by side: across for top/bottom, stacked for the
  /// side seats, whose fans open sideways.
  final Axis? axis;

  @override
  State<SeatView> createState() => _SeatViewState();
}

class _SeatViewState extends State<SeatView> {
  /// The bid just announced, shown in a bubble for a moment.
  int? _announcedBid;
  Timer? _bubbleTimer;

  bool get _isYou => widget.slot == SeatSlot.bottom;

  @override
  void didUpdateWidget(SeatView old) {
    super.didUpdateWidget(old);
    final bid = widget.bid;
    if (old.bid == null && bid != null && !_isYou) {
      _announcedBid = bid;
      _bubbleTimer?.cancel();
      _bubbleTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _announcedBid = null);
      });
    } else if (bid == null && _announcedBid != null) {
      _bubbleTimer?.cancel();
      _announcedBid = null;
    }
  }

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final slot = widget.slot;
    final avatarSize = _isYou ? m.sc(44, 42) : m.sc(44, 40);
    final avatar = RepaintBoundary(
      child: _Avatar(
        player: widget.player,
        palette: widget.palette,
        isYou: _isYou,
        isTurn: widget.isTurn,
        deadline: widget.deadline,
        size: avatarSize,
        slot: slot,
        handCount: _isYou ? null : widget.handCount,
      ),
    );
    final nameChip = _NameChip(
      player: widget.player,
      isDealer: widget.isDealer,
      isHost: widget.isHost,
      highlighted: widget.isTurn,
    );
    final bidChip = _BidChip(bid: widget.bid, tricksWon: widget.tricksWon);
    final gap = SizedBox(width: m.sc(6, 4), height: m.sc(5, 3));

    final axis =
        widget.axis ??
        (slot == SeatSlot.left || slot == SeatSlot.right
            ? Axis.vertical
            : Axis.horizontal);
    final body = Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: [nameChip, gap, avatar, gap, bidChip],
    );

    final bubble = _BidBubble(bid: _announcedBid, slot: slot);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        body,
        // Speech bubbles open toward the middle of the table, where there is
        // room and where the eye already is.
        switch (slot) {
          SeatSlot.top => Positioned(top: avatarSize + m.s(40), child: bubble),
          SeatSlot.left => Positioned(
            left: avatarSize + m.s(34),
            child: bubble,
          ),
          SeatSlot.right => Positioned(
            right: avatarSize + m.s(34),
            child: bubble,
          ),
          SeatSlot.bottom => Positioned(
            bottom: avatarSize + m.s(8),
            child: bubble,
          ),
        },
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.player,
    required this.palette,
    required this.isYou,
    required this.isTurn,
    required this.deadline,
    required this.size,
    required this.slot,
    required this.handCount,
  });

  final PlayerInfo player;
  final ThemePalette palette;
  final bool isYou;
  final bool isTurn;
  final DateTime? deadline;
  final double size;
  final SeatSlot slot;
  final int? handCount;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final ring = size + m.s(10);

    return SizedBox(
      width: ring,
      height: ring,
      child: Stack(
        alignment: Alignment.center,
        // The face-down hand fan opens out past the ring toward the table.
        clipBehavior: Clip.none,
        children: [
          ..._handFanCards(m),
          _TurnRing(active: isTurn, diameter: ring),
          Container(
            width: size,
            height: size,
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
                    : [
                        Color.lerp(
                          palette.avatar.first,
                          const Color(0xFFFFFFFF),
                          0.12,
                        )!,
                        palette.avatar.first,
                        palette.avatar.last,
                      ],
              ),
              border: Border.all(
                color: isYou
                    ? AppColors.goldLight.withValues(alpha: 0.95)
                    : AppColors.goldBorder.withValues(
                        alpha: isTurn ? 0.9 : 0.35,
                      ),
                width: isYou ? 2 : 1.6,
              ),
              boxShadow: AppShadows.low,
            ),
            child: Text(
              player.initial,
              style: AppText.bold(
                size * 0.42,
                isYou ? AppColors.onGold : AppColors.textOnDark,
              ),
            ),
          ),
          // Offline: veil the avatar so an absent player is obvious even in
          // peripheral vision.
          if (!player.connected)
            Container(
              width: size,
              height: size,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xB3000000),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.wifi_off_rounded,
                size: size * 0.38,
                color: AppColors.textMuted,
              ),
            ),

          // A bot is driving this seat — the occupant is a bot outright, or
          // their connection dropped and the table stopped waiting for them.
          if (player.isBot || !player.connected)
            Align(
              alignment: Alignment.topLeft,
              child: _BotBadge(size: size * 0.36),
            ),

          // Autoplay: still here and connected, but the table stopped waiting.
          // One tap away from being theirs again, so a different corner.
          if (player.autoplay && player.connected)
            Align(
              alignment: Alignment.topRight,
              child: _BotBadge(size: size * 0.36),
            ),

          // Presence lamp, for human seats only.
          if (!player.isBot)
            Align(
              alignment: Alignment.bottomRight,
              child: _PresenceDot(online: player.connected, size: size * 0.28),
            ),

          // Last, so the clock draws over everything — when it shows at all it
          // is the most urgent thing on the table.
          if (deadline case final due?)
            TurnClock(deadline: due, diameter: ring, audible: isYou),
        ],
      ),
    );
  }

  /// The opponent's face-down hand, fanned in an arc in front of their avatar
  /// (toward the table centre), pivoting on the avatar's centre.
  List<Widget> _handFanCards(Metrics m) {
    final count = handCount ?? 0;
    if (count <= 0 || isYou) return const [];

    final cardWidth = m.sc(24, 20);
    final cardHeight = cardWidth * CardBackView.aspect;
    final ring = size + m.s(10);
    final cx = ring / 2;
    final cy = ring / 2;
    final sweep = (count - 1) * 0.13;

    final (double fx, double fy, double base) = switch (slot) {
      SeatSlot.top => (0.0, 1.0, 0.0),
      SeatSlot.left => (1.0, 0.0, -math.pi / 2),
      SeatSlot.right => (-1.0, 0.0, math.pi / 2),
      SeatSlot.bottom => (0.0, -1.0, math.pi),
    };

    return [
      for (var i = 0; i < count; i++)
        Builder(
          builder: (context) {
            final t = count == 1 ? 0.0 : (i / (count - 1)) - 0.5;
            final theta = t * sweep;
            final dirX = fx * math.cos(theta) - fy * math.sin(theta);
            final dirY = fx * math.sin(theta) + fy * math.cos(theta);
            final centerX = cx + dirX * (cardHeight * 0.55);
            final centerY = cy + dirY * (cardHeight * 0.55);
            return Positioned(
              left: centerX - cardWidth / 2,
              top: centerY - cardHeight / 2,
              child: Transform.rotate(
                angle: base + theta,
                child: CardBackView(
                  width: cardWidth,
                  palette: palette,
                  // Only the frontmost card casts a shadow.
                  shadow: i == count - 1,
                ),
              ),
            );
          },
        ),
    ];
  }
}

/// The ring round the seat whose turn it is. It pings once — a ripple
/// spreading off the avatar — the moment the turn arrives, then holds as a
/// steady glow: loud enough to catch the eye at the change, calm while the
/// player thinks. (A forever-looping pulse would also never let a widget test
/// settle.)
class _TurnRing extends StatefulWidget {
  const _TurnRing({required this.active, required this.diameter});

  final bool active;
  final double diameter;

  @override
  State<_TurnRing> createState() => _TurnRingState();
}

class _TurnRingState extends State<_TurnRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ping = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _ping.forward();
  }

  @override
  void didUpdateWidget(_TurnRing old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _ping.forward(from: 0);
  }

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.diameter;
    return AnimatedOpacity(
      opacity: widget.active ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      child: AnimatedBuilder(
        animation: _ping,
        builder: (context, _) {
          final t = Motion.enter.transform(_ping.value);
          final pinging = _ping.isAnimating;
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (pinging)
                Container(
                  width: d * (1 + 0.55 * t),
                  height: d * (1 + 0.55 * t),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.turnGlow.withValues(
                        alpha: 0.8 * (1 - t),
                      ),
                      width: 2,
                    ),
                  ),
                ),
              Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.turnGlow, width: 2.2),
                  boxShadow: AppShadows.glow(
                    AppColors.turnGlow,
                    strength: 1.1,
                    blur: 16,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// "Bid 4" in a speech bubble, popping out of a seat for a moment when that
/// player commits to their bid.
class _BidBubble extends StatelessWidget {
  const _BidBubble({required this.bid, required this.slot});

  final int? bid;
  final SeatSlot slot;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final value = bid;
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        ),
        child: value == null
            ? const SizedBox.shrink()
            : Container(
                key: ValueKey(value),
                padding: EdgeInsets.symmetric(
                  horizontal: m.s(11),
                  vertical: m.s(6),
                ),
                decoration: BoxDecoration(
                  gradient: goldButtonGradient,
                  borderRadius: BorderRadius.circular(m.s(12)),
                  boxShadow: AppShadows.glow(AppColors.goldDeep, strength: 0.8),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Bid ',
                        style: AppText.semiBold(m.s(11), AppColors.onGold),
                      ),
                      TextSpan(
                        text: '$value',
                        style: AppText.bold(m.s(15), AppColors.onGold),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// Marks a seat the table is playing on its occupant's behalf.
class _BotBadge extends StatelessWidget {
  const _BotBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xF00A1207),
        border: Border.all(color: AppColors.goldMid, width: size * 0.09),
      ),
      child: Icon(
        Icons.smart_toy_outlined,
        size: size * 0.58,
        color: AppColors.goldMid,
      ),
    );
  }
}

/// A small lamp showing whether a seated player is reachable.
class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.online, required this.size});

  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? AppColors.success : AppColors.textMuted,
        border: Border.all(color: const Color(0xE60A1207), width: size * 0.18),
        boxShadow: online
            ? [
                BoxShadow(
                  color: AppColors.success.withValues(alpha: 0.55),
                  blurRadius: size * 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Dark glass plate shared by the name and bid chips.
class _Chip extends StatelessWidget {
  const _Chip({required this.padding, required this.child, this.border});

  final EdgeInsets padding;
  final Widget child;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xE0061410),
        border: Border.all(color: border ?? AppColors.hairlineStrong),
        borderRadius: BorderRadius.circular(m.sc(10, 8)),
        boxShadow: AppShadows.low,
      ),
      child: child,
    );
  }
}

class _NameChip extends StatelessWidget {
  const _NameChip({
    required this.player,
    required this.isDealer,
    required this.isHost,
    required this.highlighted,
  });

  final PlayerInfo player;
  final bool isDealer;
  final bool isHost;

  /// Their turn — the plate's border warms to match the ring.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final badge = m.sc(14, 11);

    return _Chip(
      border: highlighted ? AppColors.turnGlow.withValues(alpha: 0.7) : null,
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(8, 6),
        vertical: m.sc(4, 3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isHost) ...[
            Container(
              width: badge,
              height: badge,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(m.sc(4, 3)),
              ),
              child: Icon(
                Icons.workspace_premium_rounded,
                size: badge * 0.72,
                color: AppColors.gold,
              ),
            ),
            SizedBox(width: m.sc(4, 3)),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.sc(84, 64)),
            child: Text(
              player.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.semiBold(
                m.sc(11.5, 10),
                highlighted ? AppColors.goldLight : AppColors.textPrimary,
              ),
            ),
          ),
          if (isDealer) ...[
            SizedBox(width: m.sc(4, 3)),
            Container(
              width: badge,
              height: badge,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: goldButtonGradient,
                borderRadius: BorderRadius.circular(badge / 2),
              ),
              child: Text(
                'D',
                style: AppText.bold(badge * 0.6, AppColors.onGold),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tricks won against the bid, as "won/bid" with a thin progress bar under it.
/// Turns green with a check once the bid is made, and floats a "+1" off itself
/// whenever a trick is taken.
class _BidChip extends StatefulWidget {
  const _BidChip({required this.bid, required this.tricksWon});

  final int? bid;
  final int tricksWon;

  @override
  State<_BidChip> createState() => _BidChipState();
}

class _BidChipState extends State<_BidChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void didUpdateWidget(_BidChip old) {
    super.didUpdateWidget(old);
    if (widget.tricksWon > old.tricksWon) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final bid = widget.bid;
    final won = widget.tricksWon;
    final made = bid != null && won >= bid;
    final progress = bid == null || bid == 0
        ? 0.0
        : (won / bid).clamp(0.0, 1.0);
    final accent = made ? AppColors.success : AppColors.gold;

    final chip = _Chip(
      border: made ? AppColors.success.withValues(alpha: 0.6) : null,
      padding: EdgeInsets.fromLTRB(
        m.sc(8, 6),
        m.sc(4, 3),
        m.sc(8, 6),
        m.sc(4, 3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (made) ...[
                Icon(
                  Icons.check_rounded,
                  size: m.sc(12, 10),
                  color: AppColors.success,
                ),
                SizedBox(width: m.sc(2, 1)),
              ],
              Text(
                bid == null ? '–' : '$won',
                style: AppText.bold(
                  m.sc(13, 11),
                  bid == null ? AppColors.textMuted : accent,
                ),
              ),
              Text(
                bid == null ? '' : '/$bid',
                style: AppText.semiBold(
                  m.sc(11, 9.5),
                  AppColors.textPrimary.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          if (bid != null) ...[
            SizedBox(height: m.sc(3, 2)),
            Container(
              width: m.sc(26, 20),
              height: m.sc(3, 2.5),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: AppColors.hairlineStrong,
                borderRadius: BorderRadius.circular(2),
              ),
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 320),
                curve: Motion.emphasized,
                widthFactor: progress,
                child: Container(
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return AnimatedBuilder(
      animation: _pop,
      child: chip,
      builder: (context, child) {
        final t = _pop.value;
        final popping = _pop.isAnimating;
        final bump = popping
            ? 0.18 * math.sin(math.pi * (t * 2.5).clamp(0.0, 1.0))
            : 0.0;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Transform.scale(scale: 1 + bump, child: child),
            if (popping)
              Positioned(
                top: -m.s(14) - m.s(18) * Motion.enter.transform(t),
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    child: Text(
                      '+1',
                      style: AppText.bold(m.s(14), AppColors.turnGlow).copyWith(
                        shadows: const [
                          Shadow(color: Color(0xCC000000), blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
