import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/rules.dart';
import '../../state/app_settings.dart';
import 'playing_card_view.dart';
import 'seat_view.dart';
import 'suit_glyph.dart';

/// The playing surface: a leather rail with a gold inlay around a lit felt,
/// plus two live layers on top of the (static, cached) paint — a spotlight
/// that swings toward whoever is to act, and a large faint suit mark in the
/// middle (the trump spade between tricks, the led suit during one).
class FeltSurface extends StatelessWidget {
  const FeltSurface({
    super.key,
    required this.palette,
    this.spotlight,
    this.leadSuit,
  });

  final ThemePalette palette;

  /// The seat being waited on, or null when nobody is (the spotlight fades).
  final SeatSlot? spotlight;

  /// The suit led in the trick under way, or null between tricks.
  final Suit? leadSuit;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The felt itself never changes during play, so it gets its own layer:
        // turn spotlights, thrown cards and seat clocks animating above it
        // never cause it to repaint.
        RepaintBoundary(child: CustomPaint(painter: _FeltPainter(palette))),
        _LeadMark(suit: leadSuit),
        _Spotlight(slot: spotlight),
      ],
    );
  }
}

/// The table's outline: a stadium whose ends are true semi-ellipses.
RRect _tableRRect(Size size) {
  final rect = Offset.zero & size;
  return RRect.fromRectAndRadius(
    rect,
    Radius.elliptical(
      size.width / 2,
      math.min(size.height / 2, size.width * 0.62),
    ),
  );
}

double _railWidth(Size size) => size.shortestSide * 0.055;

class _FeltPainter extends CustomPainter {
  const _FeltPainter(this.palette);

  final ThemePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = _tableRRect(size);
    final rail = _railWidth(size);
    final rect = Offset.zero & size;

    // Cast shadow, so the table sits on the room rather than being printed on it.
    canvas.drawRRect(
      outer.shift(Offset(0, rail * 0.5)),
      Paint()
        ..color = const Color(0x8C000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, rail * 0.9),
    );

    // Dark leather rail, tinted toward the felt so every colourway agrees.
    final leather = Color.lerp(
      const Color(0xFF2B231E),
      palette.felt.last,
      0.22,
    )!;
    canvas.drawRRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(leather, const Color(0xFFFFFFFF), 0.1)!,
            leather,
            Color.lerp(leather, const Color(0xFF000000), 0.45)!,
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect),
    );
    canvas.drawRRect(
      outer.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x1FFFFFFF),
    );

    // Gold inlay running round the rail.
    canvas.drawRRect(
      outer.deflate(rail * 0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = AppColors.goldBorder.withValues(alpha: 0.55),
    );

    // The felt: lit from just above centre, falling off toward the rail.
    final felt = outer.deflate(rail);
    canvas.drawRRect(
      felt,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.12),
          radius: 0.78,
          colors: [
            Color.lerp(palette.felt.first, const Color(0xFFFFFFFF), 0.06)!,
            palette.felt[1],
            palette.felt.last,
          ],
          stops: const [0.0, 0.62, 1.0],
        ).createShader(felt.outerRect),
    );

    // Inner shadow where the felt meets the rail.
    canvas.save();
    canvas.clipRRect(felt);
    canvas.drawRRect(
      felt.inflate(rail * 0.35),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rail * 0.9
        ..color = const Color(0x8C000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, rail * 0.55),
    );
    canvas.restore();

    // The faint "pot" ring.
    canvas.drawRRect(
      felt.deflate(size.shortestSide * 0.16),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AppColors.goldBorder.withValues(alpha: 0.13),
    );
  }

  @override
  bool shouldRepaint(_FeltPainter old) => old.palette != palette;
}

/// Big, faint suit mark at the centre of the felt.
class _LeadMark extends StatelessWidget {
  const _LeadMark({required this.suit});

  final Suit? suit;

  @override
  Widget build(BuildContext context) {
    final lead = suit;
    final color = switch (lead) {
      null => AppColors.goldBorder.withValues(alpha: 0.08),
      final s when s.isRed => const Color(0x26FF6F61),
      _ => const Color(0x1FFFFFFF),
    };
    return LayoutBuilder(
      builder: (context, c) => Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Motion.enter,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.8, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: SuitGlyph(
            key: ValueKey(lead),
            suit: lead ?? Suit.spades,
            size: c.biggest.shortestSide * 0.34,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// A warm pool of light on the felt in front of the seat being waited on. It
/// glides round the table (the short way) as the turn passes, so the eye is
/// pulled to the next player without anything blinking.
class _Spotlight extends StatefulWidget {
  const _Spotlight({required this.slot});

  final SeatSlot? slot;

  @override
  State<_Spotlight> createState() => _SpotlightState();
}

class _SpotlightState extends State<_Spotlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  double _fromAngle = 0;
  double _toAngle = 0;
  double _fromIntensity = 0;
  double _toIntensity = 0;

  static double _angleOf(SeatSlot slot) => switch (slot) {
    SeatSlot.bottom => math.pi / 2,
    SeatSlot.top => -math.pi / 2,
    SeatSlot.left => math.pi,
    SeatSlot.right => 0,
  };

  @override
  void initState() {
    super.initState();
    final slot = widget.slot;
    if (slot != null) {
      _toAngle = _fromAngle = _angleOf(slot);
      _toIntensity = 1;
    }
    _controller.value = 1;
  }

  double get _t => Motion.emphasized.transform(_controller.value);
  double get _angle => _fromAngle + (_toAngle - _fromAngle) * _t;
  double get _intensity =>
      _fromIntensity + (_toIntensity - _fromIntensity) * _t;

  @override
  void didUpdateWidget(_Spotlight old) {
    super.didUpdateWidget(old);
    if (old.slot == widget.slot) return;
    final angle = _angle;
    final intensity = _intensity;
    _fromAngle = angle;
    _fromIntensity = intensity;
    final slot = widget.slot;
    if (slot == null) {
      _toAngle = angle;
      _toIntensity = 0;
    } else {
      var target = _angleOf(slot);
      // Always travel the short way round.
      while (target - angle > math.pi) {
        target -= 2 * math.pi;
      }
      while (target - angle < -math.pi) {
        target += 2 * math.pi;
      }
      // Fading in from nothing: start already pointing at the seat.
      if (intensity < 0.05) _fromAngle = target;
      _toAngle = target;
      _toIntensity = 1;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _SpotlightPainter(angle: _angle, intensity: _intensity),
        ),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({required this.angle, required this.intensity});

  final double angle;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0.01) return;
    final felt = _tableRRect(size).deflate(_railWidth(size));
    final center = size.center(Offset.zero);
    final focus =
        center +
        Offset(
          math.cos(angle) * size.width * 0.4,
          math.sin(angle) * size.height * 0.4,
        );
    final radius = size.shortestSide * 0.62;
    canvas.save();
    canvas.clipRRect(felt);
    canvas.drawCircle(
      focus,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.turnGlow.withValues(alpha: 0.26 * intensity),
            AppColors.turnGlow.withValues(alpha: 0.09 * intensity),
            AppColors.turnGlow.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: focus, radius: radius)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.angle != angle || old.intensity != intensity;
}

// ------------------------------------------------------------ trick cards

/// The width cards on the felt are drawn at, for a felt box of [box]. Shared
/// with the table's own throw-flight layer, which has to land its card at
/// exactly the size [TrickCluster] then settles it at.
double trickCardWidth(Metrics m, Size box) => m
    .s(58)
    .clamp(0.0, math.min(box.width * 0.19, box.height * 0.27))
    .toDouble();

/// The path a thrown card travels: a gentle arc (bowing to the right of its
/// direction of travel, so every seat's throws swirl the same way), turning
/// from [startAngle] to [endAngle], and scaling from [startScale] to 1 with a
/// slight rise mid-air — the "toss".
///
/// Pure geometry, so the table's top-level flight layer and [TrickCluster]
/// can each evaluate it and agree to the pixel at the moment one hands the
/// card to the other.
class ThrowPath {
  const ThrowPath({
    required this.start,
    required this.end,
    this.startScale = 1,
    this.startAngle = 0,
    this.endAngle = 0,
    this.bulge = 0.16,
  });

  final Offset start;
  final Offset end;
  final double startScale;
  final double startAngle;
  final double endAngle;

  /// How far the arc bows out, as a fraction of the throw's length.
  final double bulge;

  /// The easing every throw uses: quick off the hand, soft landing.
  static const curve = Curves.easeOutCubic;

  Offset positionAt(double t) {
    final d = end - start;
    final length = d.distance;
    if (length < 1) return Offset.lerp(start, end, t)!;
    final mid = Offset.lerp(start, end, 0.5)!;
    final control = mid + Offset(-d.dy, d.dx) / length * (length * bulge);
    final u = 1 - t;
    return start * (u * u) + control * (2 * u * t) + end * (t * t);
  }

  double angleAt(double t) => startAngle + (endAngle - startAngle) * t;

  double scaleAt(double t) =>
      startScale + (1 - startScale) * t + 0.12 * math.sin(math.pi * t);
}

/// The cards on the felt for the trick in progress, laid out in a fixed
/// diamond around the felt's centre: each card rests toward the side of
/// whoever threw it, so cards already down never shift as later ones join.
///
/// Cards arrive along a [ThrowPath] from the seat that played them — face
/// down from an opponent, turning over in mid-air — and rest at a slight,
/// card-specific angle the way real throws land. The card currently winning
/// glows and sits on top. Once the trick is decided the cards slide together
/// onto the winner's card, which pulses, and the stack sweeps away to the
/// winner's seat.
class TrickCluster extends StatefulWidget {
  const TrickCluster({
    super.key,
    required this.plays,
    required this.viewer,
    required this.cardWidth,
    required this.seatAnchors,
    this.throwOrigins = const {},
    this.hiddenIds = const {},
    this.settledIds = const {},
    this.winner,
    this.restBias = Offset.zero,
  });

  final List<TrickPlay> plays;
  final int? viewer;
  final double cardWidth;

  /// Offset applied to every card's rest position, so the resting diamond is
  /// centred on the felt's own visual centre rather than this stack's centre.
  final Offset restBias;

  /// Card ids whose entrance a separate top-level flight layer is animating
  /// (see `_ThrowFlight` in table_screen.dart) — those paint above the hand,
  /// which this cluster cannot. They stay invisible here until it hands off.
  final Set<String> hiddenIds;

  /// Card ids that arrived by that flight layer and so mount already at rest:
  /// the flight has done the travelling, and replaying it here would show the
  /// card jump back along its path at the handoff.
  final Set<String> settledIds;

  /// Real measured on-screen centre of each seat (or, for [SeatSlot.bottom],
  /// the local player's plate), relative to the felt's own centre. A slot can
  /// be absent for a frame or two before layout, which falls back to a reach.
  final Map<SeatSlot, Offset> seatAnchors;

  /// Per-card start override for cards this client threw itself: where the
  /// finger released it, relative to the felt's centre.
  final Map<String, Offset> throwOrigins;

  /// Set during the linger between the trick completing and the host clearing
  /// it. Drives the gather-and-sweep.
  final int? winner;

  /// Fixed rest position for a card thrown from [slot]. Static so the table's
  /// flight layer lands its card at exactly the same spot.
  static Offset restOffsetFor(
    SeatSlot slot,
    double cardWidth,
    Offset restBias,
  ) {
    final dx = cardWidth * 1.02;
    final dy = cardWidth * PlayingCardView.aspect * 0.54;
    return restBias +
        switch (slot) {
          SeatSlot.bottom => Offset(0, dy),
          SeatSlot.left => Offset(-dx, 0),
          SeatSlot.top => Offset(0, -dy),
          SeatSlot.right => Offset(dx, 0),
        };
  }

  /// The small resting tilt of [card] — stable per card, so the same card
  /// always lands the same way, in the flight layer and here alike.
  static double restAngleFor(PlayingCard card) {
    var h = 0;
    for (final unit in card.id.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return ((h % 1000) / 1000 - 0.5) * 0.16;
  }

  @override
  State<TrickCluster> createState() => _TrickClusterState();
}

class _TrickClusterState extends State<TrickCluster> {
  bool _collecting = false;
  Timer? _collectTimer;

  @override
  void dispose() {
    _collectTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TrickCluster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.winner != null && oldWidget.winner == null) {
      // Let the trick-completing card (thrown at the same instant the winner
      // was decided) land before anything starts to gather.
      final scale = Motion.trickScale(Motion.scaleOf(context));
      _collectTimer?.cancel();
      _collectTimer = Timer(Motion.scaled(Motion.throwMs, scale), () {
        if (mounted && widget.winner != null) {
          setState(() => _collecting = true);
        }
      });
    } else if (widget.winner == null && oldWidget.winner != null) {
      _collectTimer?.cancel();
      _collecting = false;
    }
  }

  Offset _anchorOr(SeatSlot slot, double reach) {
    final anchor = widget.seatAnchors[slot];
    if (anchor != null) return anchor;
    return switch (slot) {
      SeatSlot.bottom => Offset(0, reach),
      SeatSlot.left => Offset(-reach, 0),
      SeatSlot.top => Offset(0, -reach),
      SeatSlot.right => Offset(reach, 0),
    };
  }

  @override
  Widget build(BuildContext context) {
    final plays = widget.plays;
    // Live leader, so the glow moves the moment a later card overtakes.
    final leadingSeat = plays.isEmpty ? null : trickWinner(plays);
    final ordered = [
      for (final p in plays)
        if (p.seat != leadingSeat) p,
      for (final p in plays)
        if (p.seat == leadingSeat) p,
    ];
    final winner = widget.winner;
    final winnerPlay = winner == null
        ? null
        : plays.where((p) => p.seat == winner).firstOrNull;
    final winnerSlot = winner == null
        ? null
        : slotFor(seat: winner, viewer: widget.viewer);

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        for (final play in ordered)
          _cardFor(play, leadingSeat, winnerSlot, winnerPlay),
      ],
    );
  }

  Widget _cardFor(
    TrickPlay play,
    int? leadingSeat,
    SeatSlot? winnerSlot,
    TrickPlay? winnerPlay,
  ) {
    final w = widget.cardWidth;
    final slot = slotFor(seat: play.seat, viewer: widget.viewer);
    final rest = TrickCluster.restOffsetFor(slot, w, widget.restBias);
    final restAngle = TrickCluster.restAngleFor(play.card);
    final mine = slot == SeatSlot.bottom;
    final origin =
        widget.throwOrigins[play.card.id] ?? _anchorOr(slot, w * 1.8);

    final winnerRest = winnerPlay == null
        ? rest
        : TrickCluster.restOffsetFor(
            slotFor(seat: winnerPlay.seat, viewer: widget.viewer),
            w,
            widget.restBias,
          );
    final winnerAngle = winnerPlay == null
        ? restAngle
        : TrickCluster.restAngleFor(winnerPlay.card);

    return _ThrownCard(
      key: ValueKey(play.card.id),
      card: play.card,
      width: w,
      highlighted: leadingSeat == play.seat,
      isWinner: winnerPlay?.seat == play.seat,
      path: ThrowPath(
        start: origin,
        end: rest,
        // Opponents' cards start small (they come out of a small face-down
        // fan) with a spin; yours start at hand size, flat.
        startScale: mine ? 1.0 : 0.55,
        startAngle: mine ? 0 : restAngle + _spinFor(slot),
        endAngle: restAngle,
      ),
      gatherOffset: winnerRest,
      gatherAngle: winnerAngle,
      collectOffset: winnerSlot == null ? rest : _anchorOr(winnerSlot, w * 2.4),
      collecting: _collecting,
      flipIn: !mine,
      hidden: widget.hiddenIds.contains(play.card.id),
      settled: widget.settledIds.contains(play.card.id),
    );
  }

  static double _spinFor(SeatSlot slot) => switch (slot) {
    SeatSlot.left => -0.9,
    SeatSlot.top => 0.7,
    SeatSlot.right => 0.9,
    SeatSlot.bottom => 0,
  };
}

/// One card on the felt. Travels its [path] once on mount (unless [settled]),
/// rests, and once [collecting] flips true gathers onto [gatherOffset] and
/// sweeps away to [collectOffset]. A rebuild that only changes [highlighted]
/// replays nothing.
class _ThrownCard extends StatefulWidget {
  const _ThrownCard({
    super.key,
    required this.card,
    required this.width,
    required this.highlighted,
    required this.isWinner,
    required this.path,
    required this.gatherOffset,
    required this.gatherAngle,
    required this.collectOffset,
    required this.collecting,
    required this.flipIn,
    this.hidden = false,
    this.settled = false,
  });

  final PlayingCard card;
  final double width;
  final bool highlighted;
  final bool isWinner;
  final ThrowPath path;
  final Offset gatherOffset;
  final double gatherAngle;
  final Offset collectOffset;
  final bool collecting;

  /// Arrive face down and turn over in mid-air (opponents' cards).
  final bool flipIn;

  /// A top-level flight elsewhere is drawing this card for now.
  final bool hidden;

  /// Mount already at rest — the flight layer did the travelling.
  final bool settled;

  @override
  State<_ThrownCard> createState() => _ThrownCardState();
}

class _ThrownCardState extends State<_ThrownCard>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: Motion.throwMs),
  );
  late final AnimationController _collect = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: Motion.gatherMs + Motion.sweepMs),
  );

  bool _started = false;
  bool _collectStarted = false;

  static const _gatherShare =
      Motion.gatherMs / (Motion.gatherMs + Motion.sweepMs);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scale = Motion.trickScale(
      SettingsScope.of(context).animationSpeed.durationScale,
    );
    _entrance.duration = Motion.scaled(Motion.throwMs, scale);
    _collect.duration = Motion.scaled(Motion.gatherMs + Motion.sweepMs, scale);
    if (!_started) {
      _started = true;
      if (widget.settled) {
        _entrance.value = 1;
      } else {
        _entrance.forward();
      }
    }
    // The card that completes a trick mounts already `collecting` (the engine
    // decides the winner in the same step that adds it), and didUpdateWidget
    // never runs on a first mount.
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
    if (_entrance.isCompleted) {
      _collect.forward();
    } else {
      void onDone(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          _entrance.removeStatusListener(onDone);
          _collect.forward();
        }
      }

      _entrance.addStatusListener(onDone);
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    _collect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidden) return const SizedBox.shrink();
    final face = PlayingCardView(
      card: widget.card,
      width: widget.width,
      highlighted: widget.highlighted,
    );
    final palette = SettingsScope.of(context).palette;
    return AnimatedBuilder(
      animation: Listenable.merge([_entrance, _collect]),
      builder: (context, _) {
        final raw = _entrance.value;
        if (raw < 1) return _inFlight(raw, face, palette);
        return _atRest(face);
      },
    );
  }

  Widget _inFlight(double raw, Widget face, ThemePalette palette) {
    final path = widget.path;
    final t = ThrowPath.curve.transform(raw);
    Widget card = face;
    if (widget.flipIn) {
      // First half: the back turning edge-on; second half: the face turning
      // in from edge-on. Reads as one continuous flip.
      final backShowing = raw < 0.5;
      final turn = backShowing ? raw / 0.5 : 1 - (raw - 0.5) / 0.5;
      card = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateY(turn * math.pi / 2),
        child: backShowing
            ? CardBackView(width: widget.width, palette: palette)
            : face,
      );
    }
    return Transform.translate(
      offset: path.positionAt(t),
      child: Transform.rotate(
        angle: path.angleAt(t),
        child: Transform.scale(scale: path.scaleAt(t), child: card),
      ),
    );
  }

  Widget _atRest(Widget face) {
    final c = _collect.value;
    final g = Motion.emphasized.transform((c / _gatherShare).clamp(0.0, 1.0));
    final s = Curves.easeInCubic.transform(
      ((c - _gatherShare) / (1 - _gatherShare)).clamp(0.0, 1.0),
    );
    final rest = widget.path.end;
    final gathered = Offset.lerp(rest, widget.gatherOffset, g)!;
    final offset = Offset.lerp(gathered, widget.collectOffset, s)!;
    final angle =
        widget.path.endAngle + (widget.gatherAngle - widget.path.endAngle) * g;
    final pulse = widget.isWinner ? 0.12 * math.sin(math.pi * g) : 0.0;
    final scale = (1 + pulse) * (1 - 0.5 * s);
    final opacity = 1 - ((s - 0.35) / 0.65).clamp(0.0, 1.0);

    Widget card = Transform.rotate(angle: angle, child: face);
    if (widget.isWinner && c > 0 && g < 1) {
      // A ring bursting off the winning card as the others gather onto it.
      final ringSize = widget.width * (1.1 + 0.9 * g);
      card = Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          card,
          IgnorePointer(
            child: Container(
              width: ringSize,
              height: ringSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.turnGlow.withValues(alpha: 0.7 * (1 - g)),
                  width: 2.5,
                ),
              ),
            ),
          ),
        ],
      );
    }
    card = Transform.translate(
      offset: offset,
      child: Transform.scale(scale: scale, child: card),
    );
    if (opacity >= 1) return card;
    return Opacity(opacity: opacity, child: card);
  }
}
