import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/rules.dart';
import '../../state/app_settings.dart';
import 'playing_card_view.dart';
import 'seat_view.dart';

/// The felt playing surface: a soft ellipse with a radial sheen and a gold
/// hairline, sized to whatever box it is given.
class FeltSurface extends StatelessWidget {
  const FeltSurface({super.key, required this.palette});

  final ThemePalette palette;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.rectangle,
        borderRadius: const BorderRadius.all(Radius.elliptical(400, 300)),
        gradient: RadialGradient(
          center: const Alignment(0, -0.15),
          radius: 0.85,
          colors: palette.felt,
          stops: const [0.0, 0.62, 1.0],
        ),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.28), width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x8C000000), blurRadius: 40, offset: Offset(0, 14)),
          BoxShadow(color: Color(0x40000000), blurRadius: 6, spreadRadius: 2),
        ],
      ),
      child: Center(
        // Inner ring, the faint "pot" marking from the design.
        child: FractionallySizedBox(
          widthFactor: 0.72,
          heightFactor: 0.66,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.elliptical(300, 220)),
              border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.12)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The cards on the felt for the trick in progress, laid out in a fixed
/// diamond/square around the felt's centre: each card rests toward the side
/// of whoever threw it (top card near top-centre, bottom near bottom-centre,
/// left near left-centre, right near right-centre). A card's rest position
/// depends only on which seat played it, never on play order or how many
/// cards are in yet, so cards already down never have to shift as later ones
/// join. Each card moves in a straight line from roughly where the seat that
/// played it sits, the currently-leading card glows continuously, and once
/// the trick is decided all four cards animate off toward the winner before
/// the caller actually clears them.
class TrickCluster extends StatefulWidget {
  const TrickCluster({
    super.key,
    required this.plays,
    required this.viewer,
    required this.cardWidth,
    required this.spread,
    required this.seatAnchors,
    this.throwOrigins = const {},
    this.hiddenIds = const {},
    this.winner,
    this.restBias = Offset.zero,
  });

  final List<TrickPlay> plays;
  final int? viewer;
  final double cardWidth;

  /// Offset applied to every card's rest position, so the resting diamond can
  /// be centred on the felt's own visual centre rather than on this stack's
  /// centre. In landscape the felt is pushed down so its bottom tucks under
  /// the player's hand, so its middle sits below the stack's middle; biasing
  /// the cards down by that gap keeps them mid-table instead of crowding the
  /// opposite seat.
  final Offset restBias;

  /// Card ids whose entrance is currently being animated by a separate,
  /// top-level flight layer (see `_ThrowFlight` in table_screen.dart) that
  /// paints above the hand, so this rendering just stays invisible until
  /// that flight finishes and hands off — see [_ThrownCard.hidden].
  final Set<String> hiddenIds;

  /// Unused now that the cluster lays cards out in fixed per-seat diamond
  /// positions instead of spreading them toward the table edges; kept so the
  /// caller's construction site doesn't need to change.
  final double spread;

  /// Real measured on-screen centre of each seat's avatar (or, for
  /// [SeatSlot.bottom], the local player's hand area), relative to the
  /// felt's own centre — the same origin these offsets are all expressed in.
  /// Populated via [GlobalKey] measurement by the caller; a slot can be
  /// absent for a frame or two before layout has happened, in which case
  /// [_startOffsetFor]/[_collectOffsetFor] fall back to an approximate reach.
  final Map<SeatSlot, Offset> seatAnchors;

  /// Per-card override for [_startOffsetFor], keyed by [PlayingCard.id]: the
  /// point (relative to the felt's centre, same origin as [seatAnchors])
  /// where the local player's finger actually released the card, so their
  /// own throws arc in from the gesture instead of snapping to the avatar.
  /// Only ever populated for cards this client itself just threw — plays
  /// from other seats (network or bots) simply have no entry and fall back
  /// to the seat anchor as before.
  final Map<String, Offset> throwOrigins;

  /// Set only during the linger window between the trick completing and the
  /// caller actually clearing it. Drives the "winner collects the trick"
  /// sweep animation; the live leading-card glow is computed independently
  /// from [plays] so it updates mid-trick too (see [trickWinner]).
  final int? winner;

  double get _cardHeight => cardWidth * PlayingCardView.aspect;

  /// A flourish tilt applied only while a card is still in flight; it eases
  /// to zero by the time the card settles, so the resting diamond stays flat.
  static const _flightTilt = <SeatSlot, double>{
    SeatSlot.bottom: 0.12,
    SeatSlot.left: -0.18,
    SeatSlot.top: -0.12,
    SeatSlot.right: 0.18,
  };

  /// Fixed rest position for a card thrown by a seat at [slot]: offset
  /// toward that seat's side of the felt so the four possible cards form a
  /// diamond around the centre. `dx >= cardWidth` and `dy >= cardHeight / 2`
  /// guarantee none of the (up to) four card rectangles ever overlap.
  Offset _restOffsetFor(SeatSlot slot) {
    final dx = cardWidth * 1.05;
    final dy = _cardHeight * 0.55;
    return restBias + switch (slot) {
      SeatSlot.bottom => Offset(0, dy),
      SeatSlot.left => Offset(-dx, 0),
      SeatSlot.top => Offset(0, -dy),
      SeatSlot.right => Offset(dx, 0),
    };
  }

  /// Where a thrown card starts its straight-line move: the real measured
  /// centre of the seat that played it (its avatar, or — for
  /// [SeatSlot.bottom] — the local player's hand area), so the motion
  /// genuinely reads as coming from that player. Falls back to a small
  /// fixed reach past the felt centre only when a measurement isn't
  /// available yet (e.g. the very first frame).
  Offset _startOffsetFor(SeatSlot slot) {
    final anchor = seatAnchors[slot];
    if (anchor != null) return anchor;
    final reach = cardWidth * 1.8;
    return switch (slot) {
      SeatSlot.bottom => Offset(0, reach),
      SeatSlot.left => Offset(-reach, 0),
      SeatSlot.top => Offset(0, -reach),
      SeatSlot.right => Offset(reach, 0),
    };
  }

  /// Where a card exits to once the trick is decided: the real measured
  /// centre of the winning seat, so the sweep reads as "the winner collects
  /// these" rather than a plain fade toward an arbitrary point. Falls back
  /// to a small fixed reach past the felt centre when unmeasured.
  Offset _collectOffsetFor(SeatSlot slot) {
    final anchor = seatAnchors[slot];
    if (anchor != null) return anchor;
    final reach = cardWidth * 2.4;
    return switch (slot) {
      SeatSlot.bottom => Offset(0, reach),
      SeatSlot.left => Offset(-reach, 0),
      SeatSlot.top => Offset(0, -reach),
      SeatSlot.right => Offset(reach, 0),
    };
  }

  @override
  State<TrickCluster> createState() => _TrickClusterState();
}

class _TrickClusterState extends State<TrickCluster> {
  // Must match _ThrownCardState's own entrance duration: the whole point of
  // this delay is to guarantee every card — including the one that just
  // completed the trick, which starts its own arc-in at the very same
  // instant the trick is decided — has actually finished landing before any
  // card (including cards played earlier, whose entrance is long since done)
  // is allowed to start sweeping away. Without this, the earlier cards would
  // start collecting immediately while the last card is still mid-flight.
  static const _entranceBaseMs = _ThrownCardState._entranceBaseMs;

  bool _collecting = false;
  double _durationScale = 1.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _durationScale = SettingsScope.of(context).animationSpeed.durationScale;
  }

  @override
  void didUpdateWidget(covariant TrickCluster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.winner != null && oldWidget.winner == null) {
      final delay = Duration(milliseconds: (_entranceBaseMs * _durationScale).round());
      Future.delayed(delay, () {
        if (mounted && widget.winner != null) {
          setState(() => _collecting = true);
        }
      });
    } else if (widget.winner == null && oldWidget.winner != null) {
      // Trick cleared and the next one has started fresh.
      _collecting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The currently-leading card, recomputed live off however many plays are
    // in so far (works on a partial trick) — this is what actually drives
    // the highlight, updating immediately if a later card overtakes it.
    final leadingSeat = widget.plays.isEmpty ? null : trickWinner(widget.plays);
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [for (final play in widget.plays) _cardFor(play, leadingSeat)],
    );
  }

  Widget _cardFor(TrickPlay play, int? leadingSeat) {
    final slot = slotFor(seat: play.seat, viewer: widget.viewer);
    final restOffset = widget._restOffsetFor(slot);
    final startOffset = widget.throwOrigins[play.card.id] ?? widget._startOffsetFor(slot);
    final winner = widget.winner;
    final winnerSlot = winner == null
        ? null
        : slotFor(seat: winner, viewer: widget.viewer);
    final collectOffset = winnerSlot == null
        ? restOffset
        : widget._collectOffsetFor(winnerSlot);
    return _ThrownCard(
      key: ValueKey(play.card.id),
      card: play.card,
      width: widget.cardWidth,
      highlighted: leadingSeat == play.seat,
      startOffset: startOffset,
      restOffset: restOffset,
      collectOffset: collectOffset,
      collecting: _collecting,
      flightTilt: TrickCluster._flightTilt[slot]!,
      hidden: widget.hiddenIds.contains(play.card.id),
    );
  }
}

/// One card thrown onto the felt: moves in a straight line from
/// [startOffset] the first time it mounts, then settles flat into
/// [restOffset]. Once [collecting]
/// flips true (the trick has been decided and is about to be cleared) it
/// animates a second time, sliding/shrinking/fading out toward
/// [collectOffset] — the winning seat's direction — so the sweep reads as
/// "the winner collects these" rather than an instant vanish. A rebuild that
/// only changes [highlighted] (the live leading-card glow) does not replay
/// either animation.
class _ThrownCard extends StatefulWidget {
  const _ThrownCard({
    super.key,
    required this.card,
    required this.width,
    required this.highlighted,
    required this.startOffset,
    required this.restOffset,
    required this.collectOffset,
    required this.collecting,
    required this.flightTilt,
    this.hidden = false,
  });

  final PlayingCard card;
  final double width;
  final bool highlighted;
  final Offset startOffset;
  final Offset restOffset;
  final Offset collectOffset;
  final bool collecting;
  final double flightTilt;

  /// While true, a top-level flight layer elsewhere on screen is animating
  /// this same card's entrance (so it can paint above the hand — see
  /// [TrickCluster.hiddenIds]); this widget just stays invisible rather than
  /// rendering its own entrance underneath. Its controllers keep running
  /// regardless, so once this flips back to false it's already at the
  /// right point in the animation.
  final bool hidden;

  @override
  State<_ThrownCard> createState() => _ThrownCardState();
}

class _ThrownCardState extends State<_ThrownCard> with TickerProviderStateMixin {
  static const _entranceBaseMs = 520;
  // Kept comfortably under (trickLinger 1100ms baseline − a full entrance):
  // the trick-completing card only starts its collect sweep once its own
  // entrance has finished, so worst case the two run back to back and both
  // need to fit inside the caller's linger window before it clears the trick.
  static const _collectBaseMs = 460;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _entranceBaseMs),
  );
  late final Animation<double> _entrance = CurvedAnimation(
    parent: _controller,
    // A gentle, zero-velocity start (unlike the old polynomial ease-out) so
    // the card is clearly still moving well past the halfway point of the
    // throw instead of arriving almost immediately.
    curve: Curves.easeOut,
  );

  late final AnimationController _collectController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _collectBaseMs),
  );
  late final Animation<double> _collect = CurvedAnimation(
    parent: _collectController,
    curve: Curves.easeIn,
  );

  bool _started = false;
  bool _collectStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-scale both throw and collect durations by the user's animation-speed
    // preference. Read on every dependency change (cheap, and picks up live
    // setting changes) but only kick a controller off once.
    final scale = SettingsScope.of(context).animationSpeed.durationScale;
    _controller.duration = Duration(milliseconds: (_entranceBaseMs * scale).round());
    _collectController.duration = Duration(
      milliseconds: (_collectBaseMs * scale).round(),
    );
    if (!_started) {
      _started = true;
      _controller.forward();
    }
    // The card that completes a trick is mounted for the very first time
    // already with `collecting == true` (the engine decides the winner in
    // the same synchronous step that adds the 4th card, so there's never an
    // intermediate render where this card exists but the trick isn't yet
    // decided). didUpdateWidget never fires on an initial mount, so it alone
    // would miss this card's sweep entirely — check here too.
    _maybeStartCollecting();
  }

  @override
  void didUpdateWidget(covariant _ThrownCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeStartCollecting();
  }

  void _maybeStartCollecting() {
    if (!widget.collecting || _collectStarted) return;
    _collectStarted = true;
    if (_controller.isCompleted) {
      _collectController.forward();
    } else {
      // The trick was decided before this card finished arcing in. Let the
      // entrance finish first so the collect sweep never jumps mid-flight.
      void onEntranceStatus(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          _controller.removeStatusListener(onEntranceStatus);
          _collectController.forward();
        }
      }

      _controller.addStatusListener(onEntranceStatus);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _collectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidden) return const SizedBox.shrink();
    final card = PlayingCardView(
      card: widget.card,
      width: widget.width,
      highlighted: widget.highlighted,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([_entrance, _collect]),
      builder: (context, child) {
        final entranceT = _entrance.value;
        if (entranceT < 1.0) {
          final fade = entranceT.clamp(0.0, 1.0);
          final offset = Offset.lerp(widget.startOffset, widget.restOffset, entranceT)!;
          final angle = widget.flightTilt * (1 - entranceT);
          return Opacity(
            opacity: fade,
            child: Transform.translate(
              offset: offset,
              child: Transform.scale(
                scale: 0.7 + 0.3 * fade,
                child: Transform.rotate(angle: angle, child: child),
              ),
            ),
          );
        }
        // Settled (and, once the trick is decided, sweeping out toward the
        // winner): collectT stays 0 until collecting starts, so this is a
        // no-op — flat at restOffset — for the entire time the trick is
        // still in progress.
        final collectT = _collect.value;
        final offset = Offset.lerp(widget.restOffset, widget.collectOffset, collectT)!;
        final scale = 1.0 - 0.55 * collectT;
        final opacity = 1.0 - collectT;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: offset,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: card,
    );
  }
}
