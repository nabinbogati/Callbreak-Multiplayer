import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../engine/card.dart';
import '../../state/app_settings.dart';
import 'playing_card_view.dart';

/// The player's own hand along the bottom of the table: overlapping cards,
/// legal ones lifted and tappable (or draggable), illegal ones dimmed and
/// inert. Pressing and holding a legal card zooms it in above its neighbours
/// so its rank/suit is unmistakable before it's actually thrown.
class HandFan extends StatefulWidget {
  const HandFan({
    super.key,
    required this.cards,
    required this.legalIds,
    required this.interactive,
    required this.cardWidth,
    this.revealedCount,
    this.onPlay,
    this.onSlotsMeasured,
  });

  final List<PlayingCard> cards;
  final Set<String> legalIds;

  /// Whether tapping/dragging a legal card should call [onPlay] — false while
  /// it is not this player's turn, so cards still render but do not respond.
  final bool interactive;
  final double cardWidth;

  /// How many of [cards] are currently revealed/visible. When fewer than
  /// [cards].length, layout still runs for the full hand (so the fan never
  /// shifts or jumps as it fills in) but only the first [revealedCount] cards
  /// are painted. Null means show all of [cards]. Used while a hand is being
  /// dealt, so the player's cards appear one at a time in real time.
  final int? revealedCount;

  /// Called when a card is thrown, with the screen (global) position of the
  /// gesture that released it — the point the finger last touched, whether
  /// that was a tap or the end of a drag — so the caller can start the card's
  /// throw animation from there instead of the seat avatar. Null only if
  /// somehow no gesture position was ever recorded.
  final void Function(PlayingCard card, Offset? releasePosition)? onPlay;

  /// Reports the global screen centre of every card's resting slot in the fan,
  /// one per [cards] entry. Fired after the fan is laid out, whenever the
  /// positions change (a size change, an orientation flip, a hand that fills
  /// differently). The dealing flourish uses this to land each flying card
  /// exactly where the real card will sit rather than on the seat avatar.
  final ValueChanged<List<Offset>>? onSlotsMeasured;

  @override
  State<HandFan> createState() => _HandFanState();
}

class _HandFanState extends State<HandFan> {
  // Tracked by card id, not list index — a card's index shifts as others are
  // played out of the hand, but its id doesn't, so this stays correct across
  // rebuilds even if the pressed card happens to move position.
  String? _pressedCardId;

  /// Last-reported slot centres, so a fan that hasn't moved does not spam the
  /// listener every rebuild.
  List<Offset>? _lastSlots;

  void _setPressed(String? cardId) {
    if (_pressedCardId == cardId) return;
    setState(() => _pressedCardId = cardId);
  }

  /// Pushes the laid-out card slot centres (global coordinates) to
  /// [HandFan.onSlotsMeasured] once the current frame has actually laid the
  /// fan out, and only when they changed.
  void _reportSlots(List<Offset> localCenters) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final centers = [for (final c in localCenters) box.localToGlobal(c)];
      if (listEquals(centers, _lastSlots)) return;
      _lastSlots = centers;
      widget.onSlotsMeasured?.call(centers);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final cardHeight = widget.cardWidth * PlayingCardView.aspect;
    final lift = m.s(14);
    // Relative to the card's own height rather than a fixed pixel count, so
    // the "how far is far enough to throw" feel stays consistent across
    // card sizes (portrait vs landscape, different screen densities): drag
    // it up by more than 30% of its height and it's released.
    final dragThreshold = cardHeight * 0.3;
    final settings = SettingsScope.of(context);
    final dragToPlayEnabled = settings.dragToPlayEnabled;
    final durationScale = settings.animationSpeed.durationScale;
    final liftDuration = Duration(milliseconds: (180 * durationScale).round());
    final returnDuration = Duration(
      milliseconds: (220 * durationScale).round(),
    );
    final zoomDuration = Duration(milliseconds: (140 * durationScale).round());

    return LayoutBuilder(
      builder: (context, constraints) {
        final n = widget.cards.length;
        final maxWidth = constraints.maxWidth;
        final fillSpacing = n <= 1
            ? 0.0
            : ((maxWidth - widget.cardWidth) / (n - 1)).clamp(
                0.0,
                double.infinity,
              );
        // Portrait keeps the traditional overlapping fan (there's rarely
        // enough width for 13 cards edge-to-edge). Landscape has width to
        // spare, so the fan stretches toward the far edges as spacing grows
        // — but capped at 70% of cardWidth, so at least 30% of each card
        // always stays overlapped by its neighbour instead of merely
        // touching.
        final spacing = n <= 1
            ? 0.0
            : m.isPortrait
            ? (widget.cardWidth * 0.55).clamp(0.0, fillSpacing)
            : fillSpacing.clamp(0.0, widget.cardWidth * 0.7);
        final fanWidth = widget.cardWidth + spacing * (n - 1);

        // The resting slot of every card in the fan, for the dealing flourish
        // to target: each card's centre in this fan's local coordinates.
        final slotCenters = [
          for (var i = 0; i < n; i++)
            Offset(
              (maxWidth - fanWidth) / 2 + spacing * i + widget.cardWidth / 2,
              lift + cardHeight / 2,
            ),
        ];
        if (widget.onSlotsMeasured != null) {
          _reportSlots(slotCenters);
        }

        // Paint order follows this list — putting the pressed card's index
        // last brings it to the front, above its neighbours, while it's
        // zoomed in for preview. Position (left/top) is still computed from
        // each card's real index below, only paint order changes.
        final visible = widget.revealedCount ?? n;
        final order = List<int>.generate(
          n,
          (i) => i,
        ).where((i) => i < visible).toList();
        final pressedIndex = _pressedCardId == null
            ? -1
            : widget.cards.indexWhere((c) => c.id == _pressedCardId);
        if (pressedIndex >= 0) {
          order
            ..remove(pressedIndex)
            ..add(pressedIndex);
        }

        return SizedBox(
          width: maxWidth,
          height: cardHeight + lift,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final i in order)
                Builder(
                  key: ValueKey(widget.cards[i].id),
                  builder: (context) {
                    final card = widget.cards[i];
                    final legal = widget.legalIds.contains(card.id);
                    // Layout runs for the full hand (n) so cards never shift
                    // as they appear; only the revealed ones paint.
                    final left = (maxWidth - fanWidth) / 2 + spacing * i;

                    return AnimatedPositioned(
                      duration: liftDuration,
                      curve: Curves.easeOut,
                      left: left,
                      top: legal && widget.interactive ? 0 : lift,
                      child: _DealReveal(
                        child: _FanCard(
                          card: card,
                          legal: legal,
                          interactive: widget.interactive,
                          dimmed:
                              widget.interactive &&
                              widget.legalIds.isNotEmpty &&
                              !legal,
                          dragEnabled: dragToPlayEnabled,
                          dragThreshold: dragThreshold,
                          cardWidth: widget.cardWidth,
                          returnDuration: returnDuration,
                          zoomDuration: zoomDuration,
                          onPlay: widget.onPlay,
                          onPressChanged: (pressed) =>
                              _setPressed(pressed ? card.id : null),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A card in the fan that reveals itself with a short fade-and-pop the moment
/// it becomes visible. While a hand is being dealt, [HandFan] mounts each card
/// exactly as it lands (only revealed cards are in the paint list), so every
/// newly dealt card pops into its resting slot in the fan rather than snapping
/// to existence.
class _DealReveal extends StatelessWidget {
  const _DealReveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
        );
      },
      child: child,
    );
  }
}

/// A single card in the fan: tappable when legal-and-interactive, and also
/// draggable (upward, toward the table) past [dragThreshold] as an
/// alternative to tapping. Releasing short of the threshold springs the card
/// back to its resting position. While held — whether about to tap or mid
/// drag — the card zooms in and rises above its neighbours so it's clearly
/// legible before the player commits to throwing it.
class _FanCard extends StatefulWidget {
  const _FanCard({
    required this.card,
    required this.legal,
    required this.interactive,
    required this.dimmed,
    required this.dragEnabled,
    required this.dragThreshold,
    required this.cardWidth,
    required this.returnDuration,
    required this.zoomDuration,
    required this.onPlay,
    required this.onPressChanged,
  });

  final PlayingCard card;
  final bool legal;
  final bool interactive;
  final bool dimmed;
  final bool dragEnabled;
  final double dragThreshold;
  final double cardWidth;

  /// Duration of the drag-release snap-back animation, pre-scaled by the
  /// user's animation speed setting.
  final Duration returnDuration;

  /// Duration of the press-to-zoom preview transition, same scaling.
  final Duration zoomDuration;
  final void Function(PlayingCard card, Offset? releasePosition)? onPlay;

  /// Notifies the parent fan when this card becomes (or stops being) the
  /// pressed one, so the fan can bring it to the front of paint order.
  final ValueChanged<bool> onPressChanged;

  @override
  State<_FanCard> createState() => _FanCardState();
}

class _FanCardState extends State<_FanCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _returnController;

  Animation<Offset>? _returnAnimation;
  Offset _dragOffset = Offset.zero;
  bool _dragging = false;
  bool _pressed = false;

  /// Set the instant a drag crosses [_FanCard.dragThreshold], so the card is
  /// thrown right then instead of waiting for the finger to actually lift —
  /// and so any further drag updates/the eventual drag-end are ignored
  /// rather than acting on a card that's already on its way out.
  bool _thrown = false;

  bool get _canDrag => widget.legal && widget.interactive && widget.dragEnabled;
  bool get _canPress => widget.legal && widget.interactive;

  @override
  void initState() {
    super.initState();
    // Built eagerly here (not as a lazy `late final` field) so it's always
    // constructed while the widget is still mounted — a card that's never
    // dragged would otherwise trigger `vsync: this` for the first time from
    // inside dispose(), which crashes because the element is deactivating.
    _returnController =
        AnimationController(vsync: this, duration: widget.returnDuration)
          ..addListener(() {
            setState(() => _dragOffset = _returnAnimation!.value);
          });
  }

  @override
  void didUpdateWidget(covariant _FanCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.returnDuration != oldWidget.returnDuration) {
      _returnController.duration = widget.returnDuration;
    }
    // A card that stops being legal/interactive mid-press (e.g. the turn
    // moves on) shouldn't stay zoomed in with no way to release it.
    if (!_canPress && _pressed) {
      _setPressed(false);
    }
  }

  @override
  void dispose() {
    _returnController.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
    widget.onPressChanged(pressed);
  }

  void _onTapDown(TapDownDetails _) {
    _setPressed(true);
  }

  void _onTapUp(TapUpDetails _) {
    _setPressed(false);
  }

  void _onTapCancel() {
    // If this cancel is because the gesture just turned into a drag,
    // onVerticalDragStart already has (or is about to) set _pressed true
    // again via _dragging — either way both fire synchronously within the
    // same gesture resolution, so no visible flicker either order.
    if (!_dragging) _setPressed(false);
  }

  void _onVerticalDragStart(DragStartDetails _) {
    if (!_canDrag) return;
    _returnController.stop();
    _dragging = true;
    _thrown = false;
    _setPressed(true);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_canDrag || !_dragging || _thrown) return;
    setState(() {
      _dragOffset += details.delta;
    });
    // Release as soon as the card has moved far enough, without waiting for
    // the finger to actually lift — a decisive enough flick should commit
    // right away rather than requiring the user to also let go.
    if (-_dragOffset.dy >= widget.dragThreshold) {
      _throwCard();
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_canDrag || _thrown) return;
    _dragging = false;
    _setPressed(false);
    _returnAnimation = Tween<Offset>(begin: _dragOffset, end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _returnController,
            curve: Curves.easeOutCubic,
          ),
        );
    _returnController.forward(from: 0);
  }

  void _throwCard() {
    _thrown = true;
    _dragging = false;
    // Deliberately not touching _pressed or _dragOffset here: the parent's
    // state update (from onPlay, below) removes this card from the hand in
    // the very same frame, so this widget is about to be unmounted outright.
    // Resetting the zoom/lift/drag transforms first — as this used to do —
    // meant they'd animate back toward the resting slot for a frame or two
    // before disappearing, reading as the card snapping back into place
    // before vanishing. Leaving everything as it was at release means it
    // just cleanly throws, exactly like the tap path (which never touches
    // these transforms at all).
    // The flight starts where the card actually is right now (resting slot
    // plus however far the drag carried it), not the original touch-down
    // point, so a flick that crossed the threshold keeps flying from the
    // spot it was thrown rather than jumping back down into the fan first.
    widget.onPlay?.call(widget.card, _currentGlobalCenter);
  }

  /// The card's current centre in screen-global coordinates: its resting slot
  /// plus the in-progress drag offset. Used as the throw's flight start so the
  /// flight lines up with the card the finger is still holding.
  Offset? get _currentGlobalCenter {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero)) + _dragOffset;
  }

  @override
  Widget build(BuildContext context) {
    final legal = widget.legal;
    final interactive = widget.interactive;
    final zoomed = _pressed;

    return Listener(
      behavior: HitTestBehavior.opaque,
      // onTapDown below only fires once the tap recognizer wins the gesture
      // arena — with a competing vertical drag that is the moment the finger
      // lifts, so a quick tap would never zoom. The raw Listener presses the
      // card the instant the pointer lands, so the preview is always there.
      onPointerDown: _canPress ? (_) => _setPressed(true) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Dragging reports the pointer-down position rather than wherever the
        // pointer had already moved once the drag recognizer won the arena, so
        // the throw's origin is the actual touch-down point (see
        // [_currentGlobalCenter]).
        dragStartBehavior: DragStartBehavior.down,
        onTapDown: _canPress ? _onTapDown : null,
        onTapUp: _canPress ? _onTapUp : null,
        onTapCancel: _canPress ? _onTapCancel : null,
        onTap: legal && interactive
            ? () => widget.onPlay?.call(widget.card, _currentGlobalCenter)
            : null,
        onVerticalDragStart: _canDrag ? _onVerticalDragStart : null,
        onVerticalDragUpdate: _canDrag ? _onVerticalDragUpdate : null,
        onVerticalDragEnd: _canDrag ? _onVerticalDragEnd : null,
        child: Transform.translate(
          offset: _dragOffset,
          child: AnimatedScale(
            // Grows in place around the card's own centre — no lift/slide —
            // so a press just enlarges it for a clearer look rather than
            // popping it out of its spot in the fan.
            scale: zoomed ? 1.25 : 1.0,
            duration: widget.zoomDuration,
            curve: Curves.easeOut,
            alignment: Alignment.center,
            child: PlayingCardView(
              card: widget.card,
              width: widget.cardWidth,
              dimmed: widget.dimmed,
              highlighted: legal && interactive,
            ),
          ),
        ),
      ),
    );
  }
}
