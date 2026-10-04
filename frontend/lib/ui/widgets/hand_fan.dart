import 'dart:math' as math;

import 'package:flutter/gestures.dart' show VelocityTracker, kTouchSlop;
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../state/app_settings.dart';
import '../haptics.dart';
import 'playing_card_view.dart';

/// Where and how a card left the hand, so the table's throw flight can start
/// exactly where the card was — position, size and tilt — rather than
/// snapping it back to a resting slot first.
class ThrowRelease {
  const ThrowRelease({required this.center, this.scale = 1, this.angle = 0});

  /// Screen-global centre of the card at the moment it was let go.
  final Offset center;

  /// Its scale relative to the fan's card width (a previewed card is bigger).
  final double scale;

  /// Its rotation, in radians.
  final double angle;
}

/// A card's resting place in the fan, in screen-global coordinates.
class FanSlot {
  const FanSlot(this.center, this.angle);

  final Offset center;
  final double angle;

  @override
  bool operator ==(Object other) =>
      other is FanSlot && other.center == center && other.angle == angle;

  @override
  int get hashCode => Object.hash(center, angle);
}

/// The player's own hand along the bottom of the table, held in a gentle arc.
///
/// One gesture surface drives the whole fan, not one detector per card, which
/// is what makes a tightly overlapped thirteen-card hand comfortable:
///
/// * **Press** a card and it rises and grows, its neighbours parting so the
///   whole face shows.
/// * **Slide sideways** and the preview follows your finger from card to card,
///   with a tick under the thumb at each one. Letting go after a slide never
///   plays anything — it is for reading the hand.
/// * **Drag up** and the card follows your finger, tilting with its motion; it
///   is thrown once it passes the threshold or is flicked upward, and springs
///   back home otherwise.
/// * **Tap** a playable card to play it (or, with "tap twice to play" on, to
///   raise it; a second tap plays).
///
/// A card that cannot be played shakes, buzzes and reports itself through
/// [onIllegal], so the table can say why.
class HandFan extends StatefulWidget {
  const HandFan({
    super.key,
    required this.cards,
    required this.legalIds,
    required this.interactive,
    required this.cardWidth,
    this.revealedCount,
    this.hiddenIds = const {},
    this.gesturesEnabled = true,
    this.onPlay,
    this.onIllegal,
    this.onNotYourTurn,
    this.onSlotsMeasured,
  });

  final List<PlayingCard> cards;
  final Set<String> legalIds;

  /// Whether a legal card can be played right now — false while it is not
  /// this player's turn, so cards still preview but never leave the hand.
  final bool interactive;
  final double cardWidth;

  /// How many of [cards] are revealed so far. Layout always runs for the full
  /// hand (so nothing shifts as it fills in); only revealed cards paint.
  /// Null shows them all. Used while a hand is being dealt.
  final int? revealedCount;

  /// Cards already thrown but not yet gone from [cards] — a networked table
  /// only removes a card once the server confirms the play. They are left out
  /// of the fan straight away so the card is never both in flight and in hand.
  final Set<String> hiddenIds;

  /// False while the deal is running: the cards are not the player's to
  /// handle until they are all down.
  final bool gesturesEnabled;

  /// A card left the hand.
  final void Function(PlayingCard card, ThrowRelease release)? onPlay;

  /// The player tried to play a card the rules do not allow right now.
  final ValueChanged<PlayingCard>? onIllegal;

  /// The player tried to throw a card while it is somebody else's turn.
  final VoidCallback? onNotYourTurn;

  /// Reports every card's resting slot (by card id), after layout and only
  /// when it changes. The dealing flourish lands each card on its slot.
  final ValueChanged<Map<String, FanSlot>>? onSlotsMeasured;

  @override
  State<HandFan> createState() => _HandFanState();
}

enum _Mode { idle, pressing, scrubbing, dragging }

/// Where every card sits at rest, for one layout pass.
class _Layout {
  _Layout({
    required this.cards,
    required this.lefts,
    required this.tops,
    required this.angles,
    required this.cardWidth,
    required this.cardHeight,
  });

  final List<PlayingCard> cards;
  final List<double> lefts;
  final List<double> tops;
  final List<double> angles;
  final double cardWidth;
  final double cardHeight;

  int indexOf(String id) => cards.indexWhere((c) => c.id == id);

  Offset centerOf(int i) =>
      Offset(lefts[i] + cardWidth / 2, tops[i] + cardHeight / 2);

  /// The topmost revealed card under [x] (later cards overlap earlier ones).
  int? hit(double x, int revealed) {
    for (var i = math.min(cards.length, revealed) - 1; i >= 0; i--) {
      if (x >= lefts[i] && x <= lefts[i] + cardWidth) return i;
    }
    return null;
  }
}

class _HandFanState extends State<HandFan> with TickerProviderStateMixin {
  int? _pointer;
  Offset _down = Offset.zero;
  Offset _dragAnchor = Offset.zero;
  _Mode _mode = _Mode.idle;
  String? _selectedId;
  VelocityTracker? _velocity;
  bool _refusedThisGesture = false;

  /// The card being dragged and how far it has been carried.
  Offset _drag = Offset.zero;
  double _tilt = 0;

  /// "Tap twice to play": the card raised by the first tap.
  String? _armedId;

  /// The card springing home after a drag that did not throw.
  String? _returningId;
  Offset _returnFrom = Offset.zero;
  double _returnTilt = 0;
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() {}));

  /// The card shaking its head.
  String? _shakeId;
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..addListener(() => setState(() {}));

  _Layout? _layout;
  Map<String, FanSlot>? _lastSlots;

  @override
  void didUpdateWidget(HandFan old) {
    super.didUpdateWidget(old);
    // The turn moved on (or the card left): nothing stays raised or held.
    if (!widget.interactive && _armedId != null) _armedId = null;
    final ids = {for (final c in widget.cards) c.id}
      ..removeAll(widget.hiddenIds);
    if (_selectedId != null && !ids.contains(_selectedId)) _clearGesture();
    if (_armedId != null && !ids.contains(_armedId)) _armedId = null;
    if (!widget.gesturesEnabled && _pointer != null) _clearGesture();
  }

  /// Drops the gesture in progress without scheduling a rebuild — for use
  /// from [didUpdateWidget], which is already followed by one.
  void _clearGesture() {
    _pointer = null;
    _mode = _Mode.idle;
    _selectedId = null;
    _drag = Offset.zero;
    _tilt = 0;
  }

  @override
  void dispose() {
    _spring.dispose();
    _shake.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- layout

  _Layout _computeLayout(BoxConstraints constraints, Metrics m) {
    final cards = [
      for (final c in widget.cards)
        if (!widget.hiddenIds.contains(c.id)) c,
    ];
    final n = cards.length;
    final w = widget.cardWidth;
    final h = w * PlayingCardView.aspect;
    final maxWidth = constraints.maxWidth;
    final fill = n <= 1 ? 0.0 : math.max(0.0, (maxWidth - w) / (n - 1));
    // Portrait overlaps the classic way; landscape has width to spare and
    // spreads out, but always keeps at least a quarter of each card covered.
    final spacing = n <= 1
        ? 0.0
        : m.isPortrait
        ? math.min(w * 0.58, fill)
        : math.min(fill, w * 0.74);
    final fanWidth = w + spacing * (n - 1);
    final start = (maxWidth - fanWidth) / 2;

    final maxSpread = m.isPortrait ? 0.34 : 0.24;
    final step = n <= 1 ? 0.0 : math.min(0.04, maxSpread / (n - 1));
    final depth = h * (m.isPortrait ? 0.08 : 0.06);
    final mid = (n - 1) / 2;
    final top = _liftSpace(m);

    return _Layout(
      cards: cards,
      cardWidth: w,
      cardHeight: h,
      lefts: [for (var i = 0; i < n; i++) start + spacing * i],
      tops: [
        for (var i = 0; i < n; i++)
          top + (mid == 0 ? 0.0 : depth * math.pow((i - mid) / mid, 2)),
      ],
      angles: [for (var i = 0; i < n; i++) (i - mid) * step],
    );
  }

  double _liftSpace(Metrics m) => m.s(16);

  void _reportSlots(_Layout layout) {
    if (widget.onSlotsMeasured == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final slots = <String, FanSlot>{
        for (var i = 0; i < layout.cards.length; i++)
          layout.cards[i].id: FanSlot(
            box.localToGlobal(layout.centerOf(i)),
            layout.angles[i],
          ),
      };
      if (_sameSlots(slots, _lastSlots)) return;
      _lastSlots = slots;
      widget.onSlotsMeasured?.call(slots);
    });
  }

  static bool _sameSlots(Map<String, FanSlot> a, Map<String, FanSlot>? b) {
    if (b == null || a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  // ------------------------------------------------------------ gestures

  int get _revealed => widget.revealedCount ?? widget.cards.length;

  bool _isLegal(PlayingCard c) => widget.legalIds.contains(c.id);

  bool _canDrag(PlayingCard c) =>
      widget.interactive &&
      _isLegal(c) &&
      SettingsScope.read(context).dragToPlayEnabled;

  PlayingCard? _card(String? id) {
    if (id == null) return null;
    for (final c in widget.cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  double get _dragThreshold => widget.cardWidth * PlayingCardView.aspect * 0.42;

  void _onDown(PointerDownEvent e) {
    if (_pointer != null || !widget.gesturesEnabled) return;
    final layout = _layout;
    if (layout == null) return;
    final i = layout.hit(e.localPosition.dx, _revealedLaidOut(layout));
    _pointer = e.pointer;
    _down = e.localPosition;
    _refusedThisGesture = false;
    _velocity = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
    if (i == null) return;
    _spring.stop();
    setState(() {
      _returningId = null;
      _selectedId = layout.cards[i].id;
      _mode = _Mode.pressing;
    });
    Haptics.tick(context);
  }

  /// The number of laid-out cards that are revealed (hidden cards never occur
  /// mid-deal, so the full-hand reveal count maps straight across).
  int _revealedLaidOut(_Layout layout) =>
      math.min(layout.cards.length, _revealed);

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _velocity?.addPosition(e.timeStamp, e.position);
    final selected = _card(_selectedId);
    if (selected == null) return;
    final delta = e.localPosition - _down;

    switch (_mode) {
      case _Mode.pressing:
        if (delta.distance < kTouchSlop) return;
        final upward = -delta.dy > delta.dx.abs() * 0.9;
        if (upward && _canDrag(selected)) {
          _beginDrag(Offset(_down.dx, _down.dy));
          _updateDrag(e.localPosition, e.delta);
        } else {
          setState(() => _mode = _Mode.scrubbing);
          _scrub(e.localPosition);
        }
      case _Mode.scrubbing:
        // Rising well above the fan from a scrub picks the card up.
        final rise = _down.dy - e.localPosition.dy;
        if (rise > widget.cardWidth * 0.5 && _canDrag(selected)) {
          _beginDrag(Offset(e.localPosition.dx, _down.dy));
          _updateDrag(e.localPosition, e.delta);
          return;
        }
        if (rise > _dragThreshold) _refuse(selected);
        _scrub(e.localPosition);
      case _Mode.dragging:
        _updateDrag(e.localPosition, e.delta);
      case _Mode.idle:
        break;
    }
  }

  void _beginDrag(Offset anchor) {
    _dragAnchor = anchor;
    _armedId = null;
    setState(() => _mode = _Mode.dragging);
  }

  void _updateDrag(Offset position, Offset delta) {
    final selected = _card(_selectedId);
    if (selected == null) return;
    setState(() {
      _drag = position - _dragAnchor;
      _tilt = (_tilt * 0.6 + (delta.dx * 0.03).clamp(-0.32, 0.32) * 0.4);
    });
    if (-_drag.dy >= _dragThreshold) _throw(selected);
  }

  void _scrub(Offset position) {
    final layout = _layout;
    if (layout == null) return;
    final i = layout.hit(position.dx, _revealedLaidOut(layout));
    if (i == null) return;
    final id = layout.cards[i].id;
    if (id == _selectedId) return;
    setState(() => _selectedId = id);
    Haptics.tick(context);
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    final selected = _card(_selectedId);
    final mode = _mode;
    final velocity = _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    _pointer = null;
    if (selected == null) return _reset();

    switch (mode) {
      case _Mode.pressing:
        _tap(selected);
      case _Mode.dragging:
        final flung = -velocity.dy > 850 && -_drag.dy > _dragThreshold * 0.3;
        if (flung) {
          _throw(selected);
        } else {
          _springHome(selected.id);
        }
      case _Mode.scrubbing:
      case _Mode.idle:
        _reset();
    }
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_mode == _Mode.dragging && _selectedId != null) {
      _springHome(_selectedId!);
    } else {
      _reset();
    }
  }

  void _tap(PlayingCard card) {
    if (!widget.interactive) return _reset();
    if (!_isLegal(card)) {
      _refuse(card);
      return _reset();
    }
    if (SettingsScope.read(context).tapTwiceToPlay && _armedId != card.id) {
      setState(() => _armedId = card.id);
      Haptics.tick(context);
      return _reset();
    }
    _throw(card);
  }

  void _throw(PlayingCard card) {
    final layout = _layout;
    final box = context.findRenderObject();
    final i = layout?.indexOf(card.id) ?? -1;
    if (layout == null || i < 0 || box is! RenderBox || !box.attached) {
      return _reset();
    }
    final visual = _visualFor(layout, i);
    final center = box.localToGlobal(visual.center + _drag);
    _pointer = null;
    Haptics.tap(context);
    widget.onPlay?.call(
      card,
      ThrowRelease(
        center: center,
        scale: visual.scale,
        angle: visual.angle + _tilt,
      ),
    );
    _armedId = null;
    _reset();
  }

  void _refuse(PlayingCard card) {
    if (_refusedThisGesture) return;
    _refusedThisGesture = true;
    setState(() => _shakeId = card.id);
    _shake.forward(from: 0);
    Haptics.nope(context);
    if (widget.interactive) {
      widget.onIllegal?.call(card);
    } else {
      widget.onNotYourTurn?.call();
    }
  }

  void _springHome(String id) {
    _returningId = id;
    _returnFrom = _drag;
    _returnTilt = _tilt;
    _reset();
    _spring.value = 1;
    _spring.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 380, damping: 24),
        1,
        0,
        0,
      ),
    );
  }

  void _reset() {
    if (!mounted) return;
    setState(() {
      _mode = _Mode.idle;
      _selectedId = null;
      _drag = Offset.zero;
      _tilt = 0;
    });
  }

  // ------------------------------------------------------------- visuals

  /// The pose card [i] should be in right now, before any drag offset.
  ({
    Offset center,
    double top,
    double left,
    double angle,
    double scale,
    double elevation,
  })
  _visualFor(_Layout layout, int i) {
    final m = Metrics.of(context);
    final card = layout.cards[i];
    final legal = _isLegal(card);
    final selectedIndex = _selectedId == null
        ? -1
        : layout.indexOf(_selectedId!);
    final selected = i == selectedIndex;
    final armed = card.id == _armedId;
    final h = layout.cardHeight;

    var left = layout.lefts[i];
    var top = layout.tops[i];
    var angle = layout.angles[i];
    var scale = 1.0;
    var elevation = 0.0;

    if (widget.interactive && legal) top -= m.s(14);
    if (widget.interactive && !legal && widget.legalIds.isNotEmpty) {
      top += m.s(4);
    }
    if (armed && !selected) {
      top -= h * 0.14;
      elevation = 0.5;
    }

    if (selectedIndex >= 0 && !selected) {
      // Neighbours part around the previewed card, falling off with distance.
      final d = i - selectedIndex;
      final push = layout.cardWidth * 0.3;
      final falloff = switch (d.abs()) {
        1 => 1.0,
        2 => 0.45,
        3 => 0.15,
        _ => 0.0,
      };
      left += d.sign * push * falloff;
    }
    if (selected) {
      final dragging = _mode == _Mode.dragging;
      top -= dragging ? 0 : h * 0.2;
      scale = dragging ? 1.12 : 1.18;
      angle = 0;
      elevation = 1;
    }
    final center = Offset(left + layout.cardWidth / 2, top + h / 2);
    return (
      center: center,
      top: top,
      left: left,
      angle: angle,
      scale: scale,
      elevation: elevation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final scale = SettingsScope.of(context).animationSpeed.durationScale;
    final slotDuration = Motion.scaled(Motion.slotMs, scale);
    final previewDuration = Motion.scaled(Motion.previewMs, scale);

    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _computeLayout(constraints, m);
        _layout = layout;
        _reportSlots(layout);
        final n = layout.cards.length;
        final revealed = _revealedLaidOut(layout);
        final selectedIndex = _selectedId == null
            ? -1
            : layout.indexOf(_selectedId!);

        // Paint order: the held/raised/returning card on top of its neighbours.
        final order = [for (var i = 0; i < revealed; i++) i];
        for (final id in [_armedId, _returningId, _selectedId]) {
          final i = id == null ? -1 : layout.indexOf(id);
          if (i >= 0 && i < revealed) {
            order
              ..remove(i)
              ..add(i);
          }
        }

        final height =
            layout.cardHeight + _liftSpace(m) + layout.cardHeight * 0.08;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: -constraints.maxWidth * 0.05,
                  right: -constraints.maxWidth * 0.05,
                  top: -height * 0.6,
                  bottom: -height * 0.1,
                  child: _TurnGlow(active: widget.interactive && n > 0),
                ),
                for (final i in order)
                  _cardAt(
                    layout,
                    i,
                    selectedIndex,
                    slotDuration,
                    previewDuration,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cardAt(
    _Layout layout,
    int i,
    int selectedIndex,
    Duration slotDuration,
    Duration previewDuration,
  ) {
    final card = layout.cards[i];
    final pose = _visualFor(layout, i);
    final legal = _isLegal(card);
    final interacting = selectedIndex >= 0 || _armedId != null;

    var extra = Offset.zero;
    var tilt = 0.0;
    if (i == selectedIndex && _mode == _Mode.dragging) {
      extra = _drag;
      tilt = _tilt;
    } else if (card.id == _returningId) {
      extra = _returnFrom * _spring.value;
      tilt = _returnTilt * _spring.value;
    }
    if (card.id == _shakeId && _shake.isAnimating) {
      final t = _shake.value;
      extra += Offset(
        math.sin(t * math.pi * 6) * (1 - t) * layout.cardWidth * 0.12,
        0,
      );
    }

    return _SlotCard(
      key: ValueKey(card.id),
      duration: interacting ? previewDuration : slotDuration,
      curve: Motion.emphasized,
      left: pose.left,
      top: pose.top,
      angle: pose.angle,
      scale: pose.scale,
      offset: extra,
      tilt: tilt,
      child: _faceFor(
        card,
        width: layout.cardWidth,
        dimmed: widget.interactive && widget.legalIds.isNotEmpty && !legal,
        highlighted: widget.interactive && legal,
        elevation: pose.elevation,
      ),
    );
  }

  /// Card faces as last built, by card id, with the inputs they were built
  /// from. Handing Flutter the very same widget instance lets it skip that
  /// card's whole subtree: while a finger drags or scrubs, only the held card
  /// actually changes, so the other twelve cost nothing per pointer move.
  final Map<String, (double, bool, bool, double, Widget)> _faces = {};

  Widget _faceFor(
    PlayingCard card, {
    required double width,
    required bool dimmed,
    required bool highlighted,
    required double elevation,
  }) {
    final cached = _faces[card.id];
    if (cached != null &&
        cached.$1 == width &&
        cached.$2 == dimmed &&
        cached.$3 == highlighted &&
        cached.$4 == elevation) {
      return cached.$5;
    }
    final face = _FlipIn(
      child: RepaintBoundary(
        child: PlayingCardView(
          card: card,
          width: width,
          dimmed: dimmed,
          highlighted: highlighted,
          elevation: elevation,
        ),
      ),
    );
    _faces[card.id] = (width, dimmed, highlighted, elevation, face);
    return face;
  }
}

/// A card's slot in the fan, gliding to new targets (slots closing up after a
/// throw, a card rising for preview) instead of jumping. [offset] and [tilt]
/// are applied immediately on top — the finger's own motion must never lag.
class _SlotCard extends ImplicitlyAnimatedWidget {
  const _SlotCard({
    super.key,
    required this.left,
    required this.top,
    required this.angle,
    required this.scale,
    required this.offset,
    required this.tilt,
    required this.child,
    required super.duration,
    super.curve,
  });

  final double left;
  final double top;
  final double angle;
  final double scale;
  final Offset offset;
  final double tilt;
  final Widget child;

  @override
  ImplicitlyAnimatedWidgetState<_SlotCard> createState() => _SlotCardState();
}

class _SlotCardState extends AnimatedWidgetBaseState<_SlotCard> {
  Tween<double>? _left;
  Tween<double>? _top;
  Tween<double>? _angle;
  Tween<double>? _scale;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _left =
        visitor(_left, widget.left, (v) => Tween<double>(begin: v as double))
            as Tween<double>?;
    _top =
        visitor(_top, widget.top, (v) => Tween<double>(begin: v as double))
            as Tween<double>?;
    _angle =
        visitor(_angle, widget.angle, (v) => Tween<double>(begin: v as double))
            as Tween<double>?;
    _scale =
        visitor(_scale, widget.scale, (v) => Tween<double>(begin: v as double))
            as Tween<double>?;
  }

  @override
  Widget build(BuildContext context) {
    final a = animation;
    return Positioned(
      left: _left!.evaluate(a) + widget.offset.dx,
      top: _top!.evaluate(a) + widget.offset.dy,
      child: Transform.rotate(
        angle: _angle!.evaluate(a) + widget.tilt,
        child: Transform.scale(scale: _scale!.evaluate(a), child: widget.child),
      ),
    );
  }
}

/// A card turning face up as it arrives in the hand: it swings in from
/// edge-on, finishing the flip the dealt card started in the air.
class _FlipIn extends StatelessWidget {
  const _FlipIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = SettingsScope.of(context).animationSpeed.durationScale;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.scaled(Motion.revealMs, scale),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) {
        if (t >= 1) return child!;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateY((1 - t) * math.pi / 2),
          child: child,
        );
      },
    );
  }
}

/// A warm glow rising behind the hand when it is the player's turn. It swells
/// a few times as the turn arrives, then settles to a steady low light.
class _TurnGlow extends StatefulWidget {
  const _TurnGlow({required this.active});

  final bool active;

  @override
  State<_TurnGlow> createState() => _TurnGlowState();
}

class _TurnGlowState extends State<_TurnGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _pulse.forward();
  }

  @override
  void didUpdateWidget(_TurnGlow old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.active ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = _pulse.value;
              // Three swells that fade into a steady 0.55.
              final swell = _pulse.isAnimating
                  ? 0.55 + 0.45 * math.sin(t * math.pi * 6).abs() * (1 - t)
                  : 0.55;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, 0.45),
                    radius: 0.7,
                    colors: [
                      AppColors.turnGlow.withValues(alpha: 0.3 * swell),
                      AppColors.turnGlow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
