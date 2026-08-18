import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/rules.dart';
import '../../net/local_session.dart';
import '../../net/remote_session.dart';
import '../../net/session.dart';
import '../../state/active_game_binding.dart';
import '../../state/app_settings.dart';
import '../widgets/backdrop.dart';
import '../widgets/playing_card_view.dart';
import 'lan_screen.dart';
import 'profile_screen.dart';
import 'settings_sheet.dart';
import 'table_screen.dart';

/// One of the four ways to start a table, straight from the design.
class PlayModeSpec {
  const PlayModeSpec({
    required this.mode,
    required this.accent,
    required this.letter,
    required this.badge,
    required this.subtitle,
  });

  final GameMode mode;
  final Color accent;
  final String letter;
  final String badge;
  final String subtitle;

  String get name => mode.label;
}

const playModes = <PlayModeSpec>[
  PlayModeSpec(
    mode: GameMode.bots,
    accent: Color(0xFF5B9BD5),
    letter: 'v',
    badge: 'Solo',
    subtitle: 'Practice against AI opponents',
  ),
  PlayModeSpec(
    mode: GameMode.online,
    accent: AppColors.danger,
    letter: 'v',
    badge: 'Online',
    subtitle: 'Quickplay or a full match',
  ),
  PlayModeSpec(
    mode: GameMode.private,
    accent: AppColors.goldBorder,
    letter: 'P',
    badge: 'Friends',
    subtitle: 'Invite-only room with a code',
  ),
  PlayModeSpec(
    mode: GameMode.lan,
    accent: AppColors.success,
    letter: 'L',
    badge: 'Local',
    subtitle: 'Play on the same Wi‑Fi network',
  ),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Guards the rejoin check to run exactly once per time this screen lands
  /// on top of the stack — [didChangeDependencies] otherwise reruns on every
  /// inherited-widget change (e.g. a theme edit in the settings sheet).
  bool _checkedRejoin = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checkedRejoin) return;
    _checkedRejoin = true;
    // Deferred a frame: showDialog needs a fully built Navigator, and this
    // runs as early as immediately after HomeScreen's own first build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOfferRejoin());
  }

  Future<void> _maybeOfferRejoin() async {
    if (!mounted) return;
    final settings = SettingsScope.of(context);
    final active = settings.identity.activeGame;
    if (active == null) return;

    final rejoin = await showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      builder: (context) => _RejoinDialog(roomCode: active.roomCode),
    );
    if (!mounted) return;

    if (rejoin != true) {
      unawaited(settings.identity.clearActiveGame());
      return;
    }

    final session = RemoteSession(
      serverUrl: active.serverUrl,
      roomCode: active.roomCode,
      playerName: active.playerName,
      mode: GameMode.values.byName(active.mode),
      guestToken: settings.guestToken,
      deviceId: settings.identity.deviceId,
      resumeToken: active.resumeToken,
    );
    wireActiveGamePersistence(settings, session);
    if (!mounted) return;
    _push(context, session);
  }

  @override
  Widget build(BuildContext context) {
    final palette = SettingsScope.of(context).palette;

    return Scaffold(
      // No text field lives on this scaffold — the join/settings sheets that
      // hold them pad themselves above the keyboard via MediaQuery viewInsets.
      // Resizing the home body behind them on every keyboard frame would
      // otherwise re-lay out and repaint the whole screen (backdrop included)
      // purely for show.
      resizeToAvoidBottomInset: false,
      body: MetricsScope(
        builder: (context) {
          final m = Metrics.of(context);
          return Backdrop(
            colors: palette.background,
            glow: palette.glow,
            horizontal: !m.isPortrait,
            glowAlignment: m.isPortrait
                ? const Alignment(-0.85, 0.0)
                : const Alignment(-0.55, -0.1),
            child: SafeArea(
              child: m.isPortrait
                  ? const _PortraitHome()
                  : const _LandscapeHome(),
            ),
          );
        },
      ),
    );
  }
}

/// Asks whether to reclaim a table found still marked active from before the
/// app last closed — the process dying mid-game (killed by the OS, a crash,
/// a swipe-away) never gets a chance to tell the server goodbye, so the seat
/// may still be there waiting out its grace window.
class _RejoinDialog extends StatelessWidget {
  const _RejoinDialog({required this.roomCode});

  final String roomCode;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: m.s(32)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.s(300)),
        child: Container(
          padding: EdgeInsets.all(m.s(20)),
          decoration: BoxDecoration(
            color: const Color(0xE604120D),
            borderRadius: BorderRadius.circular(m.s(18)),
            border: Border.all(
              color: AppColors.goldBorder.withValues(alpha: 0.35),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 30,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Rejoin your game?',
                textAlign: TextAlign.center,
                style: AppText.bold(m.s(16), AppColors.textPrimary),
              ),
              SizedBox(height: m.s(8)),
              Text(
                'You still have a seat held at table $roomCode.',
                textAlign: TextAlign.center,
                style: AppText.medium(m.s(13), AppColors.textMuted),
              ),
              SizedBox(height: m.s(20)),
              Row(
                children: [
                  Expanded(
                    child: PressFeedback(
                      onTap: () => Navigator.of(context).pop(false),
                      child: Container(
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(vertical: m.s(13)),
                        decoration: BoxDecoration(
                          color: AppColors.panel,
                          borderRadius: BorderRadius.circular(m.s(14)),
                          border: Border.all(color: AppColors.hairlineStrong),
                        ),
                        child: Text(
                          'Discard',
                          style: AppText.semiBold(
                            m.s(13),
                            AppColors.textOnDark,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: m.s(12)),
                  Expanded(
                    child: PressFeedback(
                      onTap: () => Navigator.of(context).pop(true),
                      child: Container(
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(vertical: m.s(13)),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.gold, AppColors.goldDeep],
                          ),
                          borderRadius: BorderRadius.circular(m.s(14)),
                        ),
                        child: Text(
                          'Rejoin',
                          style: AppText.bold(m.s(13), AppColors.onGold),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- portrait

class _PortraitHome extends StatelessWidget {
  const _PortraitHome();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(m.s(20), m.s(8), m.s(20), 0),
          child: const _TopBar(),
        ),
        SizedBox(height: m.s(12)),
        const _Hero(compact: false),
        SizedBox(height: m.s(16)),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(m.s(20), 0, m.s(20), m.s(8)),
            children: [
              Text(
                'Choose how to play',
                style: AppText.semiBold(m.s(13), AppColors.textMuted),
              ),
              SizedBox(height: m.s(12)),
              for (final spec in playModes) ...[
                _ModeRow(spec: spec),
                SizedBox(height: m.s(12)),
              ],
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: m.s(10)),
          child: Text(
            'Spades trump · Best of 5 hands',
            style: AppText.medium(m.s(11), AppColors.textFaint),
          ),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------- landscape

class _LandscapeHome extends StatelessWidget {
  const _LandscapeHome();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(m.s(28), m.s(6), m.s(28), 0),
          child: const _TopBar(),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(flex: 40, child: _Hero(compact: true)),
              Expanded(
                flex: 52,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(m.s(8), 0, m.s(28), m.s(8)),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose how to play',
                        style: AppText.semiBold(m.s(12), AppColors.textMuted),
                      ),
                      SizedBox(height: m.s(10)),
                      for (var row = 0; row < 2; row++) ...[
                        Row(
                          children: [
                            for (var col = 0; col < 2; col++) ...[
                              Expanded(
                                child: _ModeTile(
                                  spec: playModes[row * 2 + col],
                                ),
                              ),
                              if (col == 0) SizedBox(width: m.s(10)),
                            ],
                          ],
                        ),
                        if (row == 0) SizedBox(height: m.s(24)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- components

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final settings = SettingsScope.of(context);

    return Row(
      children: [
        GlassPill(
          radius: m.s(22),
          padding: EdgeInsets.symmetric(horizontal: m.s(15), vertical: m.s(10)),
          border: AppColors.hairlineStrong,
          // The player's own name is the natural door to their profile — it is
          // already the one thing on this screen that is about them.
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: m.s(10),
                height: m.s(10),
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: m.s(7)),
              Text(
                settings.playerName,
                style: AppText.semiBold(m.s(14), AppColors.textOnDark),
              ),
              SizedBox(width: m.s(7)),
              Icon(
                Icons.chevron_right_rounded,
                size: m.s(18),
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
        const Spacer(),
        GlassPill(
          radius: m.s(22),
          padding: EdgeInsets.all(m.s(11)),
          border: AppColors.hairlineStrong,
          onTap: () => showSettingsSheet(context),
          child: Icon(
            Icons.tune_rounded,
            size: m.s(22),
            color: AppColors.textOnDark,
          ),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final palette = SettingsScope.of(context).palette;
    final cardWidth = m.s(compact ? 64 : 72);
    final fanWidth = m.s(compact ? 168 : 184);
    final fanHeight = m.s(compact ? 108 : 122);
    final tilt = compact ? 12.0 : 14.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: fanWidth,
          height: fanHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: m.s(18),
                child: CardBackView(
                  width: cardWidth,
                  palette: palette,
                  rotation: tilt * math.pi / 180,
                  spadeEmblem: true,
                ),
              ),
              Positioned(
                left: m.s(compact ? 52 : 56),
                top: m.s(8),
                child: CardBackView(
                  width: cardWidth,
                  palette: palette,
                  spadeEmblem: true,
                ),
              ),
              Positioned(
                left: m.s(compact ? 96 : 104),
                top: 0,
                child: CardBackView(
                  width: cardWidth,
                  palette: palette,
                  rotation: -tilt * math.pi / 180,
                  spadeEmblem: true,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: m.s(10)),
        GoldGradientText(
          'CALL BREAK',
          style: AppText.wordmark(m.s(compact ? 36 : 42)),
        ),
        SizedBox(height: m.s(4)),
        Text(
          'Bid. Break. Win.',
          style: AppText.medium(
            m.s(compact ? 14 : 16),
            AppColors.textSubtle,
            letterSpacing: m.s(compact ? 0.84 : 1.28),
          ),
        ),
      ],
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.spec});

  final PlayModeSpec spec;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return _ModeSurface(
      spec: spec,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: m.s(16), vertical: m.s(18)),
        child: Row(
          children: [
            _ModeIcon(
              spec: spec,
              size: m.s(44),
              fontSize: m.s(18),
              radius: m.s(12),
            ),
            SizedBox(width: m.s(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          spec.name,
                          style: AppText.bold(m.s(15), AppColors.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: m.s(8)),
                      _ModeBadge(spec: spec, fontSize: m.s(10)),
                    ],
                  ),
                  SizedBox(height: m.s(3)),
                  Text(
                    spec.subtitle,
                    style: AppText.medium(m.s(12), AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(width: m.s(8)),
            Icon(
              Icons.chevron_right_rounded,
              size: m.s(24),
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.spec});

  final PlayModeSpec spec;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return _ModeSurface(
      spec: spec,
      child: Padding(
        padding: EdgeInsets.all(m.s(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _ModeIcon(
                  spec: spec,
                  size: m.s(28),
                  fontSize: m.s(13),
                  radius: m.s(8),
                ),
                SizedBox(width: m.s(8)),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      spec.name,
                      style: AppText.bold(m.s(14), AppColors.textPrimary),
                    ),
                  ),
                ),
                SizedBox(width: m.s(6)),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: _ModeBadge(spec: spec, fontSize: m.s(9)),
                  ),
                ),
              ],
            ),
            SizedBox(height: m.s(6)),
            Text(
              spec.subtitle,
              style: AppText.medium(m.s(11), AppColors.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeSurface extends StatelessWidget {
  const _ModeSurface({required this.spec, required this.child});

  final PlayModeSpec spec;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final radius = BorderRadius.circular(m.s(14));

    // A soft drop shadow lifts the card off the backdrop so it reads as
    // pressable — paired with the instant press feedback it makes the whole
    // surface feel like a button rather than a flat plate. A slow glow travels
    // the border to keep the card quietly alive.
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: m.s(18),
            offset: Offset(0, m.s(6)),
          ),
        ],
      ),
      child: _RunningBorderGlow(
        accent: spec.accent,
        radius: radius,
        child: PressFeedback(
          onTap: () => startTable(context, spec.mode),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0x80061A14),
              borderRadius: radius,
              border: Border.all(color: spec.accent.withValues(alpha: 0.4)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Draws a slow, soft light that travels around a rounded border, so a card
/// feels gently alive without any movement of its content.
class _RunningBorderGlow extends StatefulWidget {
  const _RunningBorderGlow({
    required this.accent,
    required this.radius,
    required this.child,
  });

  final Color accent;
  final BorderRadius radius;
  final Widget child;

  @override
  State<_RunningBorderGlow> createState() => _RunningBorderGlowState();
}

class _RunningBorderGlowState extends State<_RunningBorderGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The controller drives the painter, but a CustomPainter only repaints
    // when its widget rebuilds — so without this the light would sit frozen
    // at one spot. AnimatedBuilder turns every tick into a repaint.
    return AnimatedBuilder(
      animation: _controller,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) => CustomPaint(
        foregroundPainter: _RunningGlowPainter(
          progress: _controller,
          accent: widget.accent,
          radius: widget.radius,
        ),
        child: child,
      ),
    );
  }
}

class _RunningGlowPainter extends CustomPainter {
  _RunningGlowPainter({
    required this.progress,
    required this.accent,
    required this.radius,
  });

  final Animation<double> progress;
  final Color accent;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.5), radius.topLeft);
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final total = metric.length;

    // A faint static border keeps the edge defined between passes.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.22),
    );

    // A short bright segment that travels the whole perimeter.
    final segment = total * 0.14;
    final start = (progress.value * total) % total;
    final end = start + segment;
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.7)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    // Wrap the tail around the corner so the light never blinks out.
    if (end > total) {
      canvas.drawPath(metric.extractPath(start, total), glow);
      canvas.drawPath(metric.extractPath(0, end - total), glow);
    } else {
      canvas.drawPath(metric.extractPath(start, end), glow);
    }
  }

  @override
  bool shouldRepaint(_RunningGlowPainter oldDelegate) =>
      oldDelegate.progress.value != progress.value ||
      oldDelegate.accent != accent ||
      oldDelegate.radius != radius;
}

class _ModeIcon extends StatelessWidget {
  const _ModeIcon({
    required this.spec,
    required this.size,
    required this.fontSize,
    required this.radius,
  });

  final PlayModeSpec spec;
  final double size;
  final double fontSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: spec.accent.withValues(alpha: 0.18),
        border: Border.all(color: spec.accent.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(spec.letter, style: AppText.bold(fontSize, spec.accent)),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.spec, required this.fontSize});

  final PlayModeSpec spec;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: m.s(8), vertical: m.s(3)),
      decoration: BoxDecoration(
        color: spec.accent.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(m.s(8)),
      ),
      child: Text(spec.badge, style: AppText.semiBold(fontSize, spec.accent)),
    );
  }
}

// ----------------------------------------------------------------- routing

/// Opens a table for [mode]. Offline modes start as soon as the player has
/// picked a match length; networked modes first collect the server address and
/// room code.
Future<void> startTable(BuildContext context, GameMode mode) async {
  final settings = SettingsScope.of(context);

  if (mode.isOffline) {
    final details = await showJoinSheet(context, mode: mode);
    if (details == null || !context.mounted) return;
    _push(
      context,
      LocalSession(
        playerName: settings.playerName,
        difficulty: settings.difficulty,
        mode: mode,
        animationSpeed: settings.animationSpeed,
        handsPerGame: details.handsPerGame ?? handsPerGame,
      ),
    );
    return;
  }

  if (mode == GameMode.lan) {
    // LAN reuses the same sheet chrome as the other modes' join popups, so
    // the popup is the same size whether the player picked private, online or
    // LAN — only the content inside the panel differs.
    await showSheet<void>(context, (_) => const LanScreen());
    return;
  }

  final details = await showJoinSheet(context, mode: mode);
  if (details == null || !context.mounted) return;

  settings.serverUrl = details.serverUrl;
  final session = RemoteSession(
    serverUrl: details.serverUrl,
    roomCode: details.roomCode,
    playerName: settings.playerName,
    mode: mode,
    difficulty: settings.difficulty,
    guestToken: settings.guestToken,
    deviceId: settings.identity.deviceId,
    handsPerGame: details.handsPerGame,
    creating: details.creating,
  );
  wireActiveGamePersistence(settings, session);
  _push(context, session);
}

void _push(BuildContext context, GameSession session) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => TableScreen(session: session)),
  );
}
