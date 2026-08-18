import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
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

/// Avatar plus name/bid plate for one player around the table.
class SeatView extends StatelessWidget {
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
  /// seat is on the clock and a real person is being waited for — a bot's turn,
  /// or a seat already playing itself, has nothing worth counting down.
  final DateTime? deadline;

  /// How many cards this seat holds, for the face-down fan shown in front of an
  /// opponent's avatar. Null (or the bottom/self seat, whose hand is on screen
  /// as the real face-up fan) renders no fan.
  final int? handCount;

  bool get _isYou => slot == SeatSlot.bottom;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final avatar = _Avatar(
      player: player,
      palette: palette,
      isYou: _isYou,
      isTurn: isTurn,
      deadline: deadline,
      size: _isYou ? m.sc(46, 45) : m.sc(38, 39),
      slot: slot,
      handCount: _isYou ? null : handCount,
    );
    final nameChip = _NameChip(player: player, isDealer: isDealer, isHost: isHost);
    final bidChip = _BidChip(bid: bid, tricksWon: tricksWon);

    final gap = SizedBox(width: m.sc(6, 4), height: m.sc(6, 4));

    return switch (slot) {
      SeatSlot.top || SeatSlot.bottom => Row(
        mainAxisSize: MainAxisSize.min,
        children: [nameChip, gap, avatar, gap, bidChip],
      ),
      SeatSlot.left || SeatSlot.right => Column(
        mainAxisSize: MainAxisSize.min,
        children: [nameChip, gap, avatar, gap, bidChip],
      ),
    };
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

  /// Which side of the table this seat is on, so the face-down hand fan can
  /// open toward the table centre.
  final SeatSlot slot;

  /// Cards held by this seat; null/0 hides the fan (the self seat never gets
  /// one — its real hand is already on screen).
  final int? handCount;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final ring = size + m.s(8);

    return SizedBox(
      width: ring,
      height: ring,
      child: Stack(
        alignment: Alignment.center,
        // The face-down hand fan opens out past the ring toward the table, so
        // the cards must not be clipped at the avatar's edge.
        clipBehavior: Clip.none,
        children: [
          ..._handFanCards(m),
          // Turn ring — animates in so the eye catches whose turn it is.
          AnimatedOpacity(
            opacity: isTurn ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Container(
              width: ring,
              height: ring,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.gold.withValues(alpha: 0.9),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(color: AppColors.gold.withValues(alpha: 0.5), blurRadius: 14),
                ],
              ),
            ),
          ),
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isYou
                    ? const [AppColors.gold, AppColors.goldDeep]
                    : palette.avatar,
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
            child: Text(
              player.initial,
              style: AppText.bold(
                size * (isYou ? 0.37 : 0.37),
                isYou ? AppColors.onGold : AppColors.textOnDark,
              ),
            ),
          ),
          // Offline: veil the avatar so an absent player is obvious even in
          // peripheral vision, rather than only on close inspection.
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

          // A bot is driving this seat — the occupant is a bot outright, or their
          // connection dropped and the table has stopped waiting for them. This
          // is the pair to the wifi-off veil above: "they are gone" and, at the
          // same time, "their hand is not stalled because of it".
          if (player.isBot || !player.connected)
            Align(
              alignment: Alignment.topLeft,
              child: _BotBadge(size: size * 0.34),
            ),

          // Autoplay: the player is still here, still connected, but the table
          // stopped waiting for them. That is a different thing from being
          // offline and gets its own mark rather than reusing the scrim — the
          // seat is one tap away from being theirs again.
          if (player.autoplay && player.connected)
            Align(
              alignment: Alignment.topRight,
              child: _BotBadge(size: size * 0.34),
            ),

          // Presence lamp, for human seats only — a bot is never "online" in
          // any sense a player cares about, and a dot on every seat would say
          // nothing. Its presence therefore also reads as "this is a person".
          if (!player.isBot)
            Align(
              alignment: Alignment.bottomRight,
              child: _PresenceDot(online: player.connected, size: size * 0.28),
            ),

          // Last, so the clock draws over the avatar and both badges — when it
          // is on screen at all it is the most urgent thing on the table.
          if (deadline case final due?)
            TurnClock(deadline: due, diameter: ring, audible: isYou),
        ],
      ),
    );
  }

  /// The opponent's face-down hand, fanned in an arc in front of their avatar
  /// (toward the table centre). The avatar's centre is the fan's pivot: every
  /// card's held edge sits there and the card reaches one card-height toward
  /// the table, rotated around the pivot — so the far ends trace a clean arc,
  /// just like cards spread in a hand. Each seat gets the same arrangement,
  /// turned to face its own direction of the table.
  List<Widget> _handFanCards(Metrics m) {
    final count = handCount ?? 0;
    if (count <= 0 || isYou) return const [];

    final cardWidth = m.sc(26, 22);
    final cardHeight = cardWidth * CardBackView.aspect;
    final ring = size + m.s(8);
    final cx = ring / 2;
    final cy = ring / 2;
    // Total fan angle in radians; a full hand opens to ~100°.
    final sweep = (count - 1) * 0.15;

    // The forward direction (toward the table centre) and the base rotation
    // that points a card's long axis along it.
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
            // The card's held edge sits on the pivot; the body reaches toward
            // the table, rotated by theta around the pivot.
            final dirX = fx * math.cos(theta) - fy * math.sin(theta);
            final dirY = fx * math.sin(theta) + fy * math.cos(theta);
            final centerX = cx + dirX * (cardHeight / 2);
            final centerY = cy + dirY * (cardHeight / 2);
            return Positioned(
              left: centerX - cardWidth / 2,
              top: centerY - cardHeight / 2,
              child: Transform.rotate(
                angle: base + theta,
                child: CardBackView(
                  width: cardWidth,
                  palette: palette,
                  // Only the frontmost card casts a shadow, so the overlap of
                  // the fan reads as held cards, not a smear of shadows.
                  shadow: i == count - 1,
                ),
              ),
            );
          },
        ),
    ];
  }
}

/// Marks a seat the table is playing on its occupant's behalf — a permanent
/// bot, a player whose connection dropped, or one who stopped responding. The
/// robot reads as "somebody is being played for", whatever the reason.
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
        color: const Color(0xE60A1207),
        border: Border.all(color: AppColors.goldMid, width: size * 0.09),
      ),
      child: Icon(Icons.smart_toy_outlined, size: size * 0.58, color: AppColors.goldMid),
    );
  }
}

/// A small lamp showing whether a seated player is reachable.
///
/// The ring is what makes it legible: the felt, the avatar gradients and the
/// themes all vary, so the dot needs its own dark border to keep its shape
/// against any of them.
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

/// Small dark panel shared by [_NameChip] and [_BidChip] so the pair reads
/// as a matched set flanking the avatar.
class _Chip extends StatelessWidget {
  const _Chip({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xD104120D),
        border: Border.all(color: AppColors.hairline),
        borderRadius: BorderRadius.circular(m.sc(11, 8)),
        boxShadow: const [
          BoxShadow(color: Color(0x73000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: child,
    );
  }
}

class _NameChip extends StatelessWidget {
  const _NameChip({required this.player, required this.isDealer, required this.isHost});

  final PlayerInfo player;
  final bool isDealer;
  final bool isHost;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return _Chip(
      padding: EdgeInsets.symmetric(horizontal: m.sc(8, 6), vertical: m.sc(4, 3)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Host badge leads the name so it reads as a title, and sits apart
          // from the transient dealer mark trailing it.
          if (isHost) ...[
            Container(
              width: m.sc(13, 10),
              height: m.sc(13, 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(m.sc(4, 3)),
              ),
              child: Icon(Icons.workspace_premium_rounded, size: m.sc(9, 7), color: AppColors.gold),
            ),
            SizedBox(width: m.sc(4, 3)),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.sc(84, 62)),
            child: Text(
              player.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.semiBold(m.sc(11, 9), AppColors.textPrimary),
            ),
          ),
          if (isDealer) ...[
            SizedBox(width: m.sc(4, 3)),
            Container(
              width: m.sc(13, 10),
              height: m.sc(13, 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(m.sc(4, 3)),
              ),
              child: Text('D', style: AppText.bold(m.sc(8, 7), AppColors.gold)),
            ),
          ],
        ],
      ),
    );
  }
}

class _BidChip extends StatelessWidget {
  const _BidChip({required this.bid, required this.tricksWon});

  final int? bid;
  final int tricksWon;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final made = bid != null && tricksWon >= bid!;

    return _Chip(
      padding: EdgeInsets.symmetric(horizontal: m.sc(7, 5), vertical: m.sc(4, 3)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(bid?.toString() ?? '–', style: AppText.bold(m.sc(12, 10), AppColors.gold)),
          SizedBox(width: m.sc(3, 2)),
          Text(
            '/',
            style: AppText.semiBold(
              m.sc(11, 9),
              AppColors.textPrimary.withValues(alpha: 0.35),
            ),
          ),
          SizedBox(width: m.sc(3, 2)),
          Text(
            '$tricksWon',
            style: AppText.bold(
              m.sc(12, 10),
              made ? AppColors.success : AppColors.textOnDark,
            ),
          ),
        ],
      ),
    );
  }
}
