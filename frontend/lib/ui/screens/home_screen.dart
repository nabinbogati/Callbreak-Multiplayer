import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/rules.dart';
import '../../net/local_session.dart';
import '../../net/remote_session.dart';
import '../../net/session.dart';
import '../../state/active_game_binding.dart';
import '../../state/app_settings.dart';
import '../widgets/backdrop.dart';
import '../widgets/buttons.dart';
import '../widgets/playing_card_view.dart';
import '../widgets/suit_glyph.dart';
import 'lan_screen.dart';
import 'profile_screen.dart';
import 'settings_sheet.dart';
import 'table_screen.dart';

/// One of the four ways to start a table, straight from the design.
class PlayModeSpec {
  const PlayModeSpec({
    required this.mode,
    required this.accent,
    required this.icon,
    required this.letter,
    required this.badge,
    required this.subtitle,
  });

  final GameMode mode;
  final Color accent;
  final IconData icon;
  final String letter;
  final String badge;
  final String subtitle;

  String get name => mode.label;
}

const playModes = <PlayModeSpec>[
  PlayModeSpec(
    mode: GameMode.bots,
    icon: Icons.smart_toy_rounded,
    accent: Color(0xFF5B9BD5),
    letter: 'v',
    badge: 'Solo',
    subtitle: 'Practice against AI opponents',
  ),
  PlayModeSpec(
    mode: GameMode.online,
    icon: Icons.public_rounded,
    accent: AppColors.danger,
    letter: 'v',
    badge: 'Online',
    subtitle: 'Quickplay or a full match',
  ),
  PlayModeSpec(
    mode: GameMode.private,
    icon: Icons.group_rounded,
    accent: AppColors.goldBorder,
    letter: 'P',
    badge: 'Friends',
    subtitle: 'Invite-only room with a code',
  ),
  PlayModeSpec(
    mode: GameMode.lan,
    icon: Icons.wifi_rounded,
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
                ? const Alignment(0, -0.55)
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
/// Asks whether to reclaim a table found still marked active from before the
/// app last closed — the process dying mid-game never gets a chance to tell
/// the server goodbye, so the seat may still be there waiting out its grace
/// window.
class _RejoinDialog extends StatelessWidget {
  const _RejoinDialog({required this.roomCode});

  final String roomCode;

  @override
  Widget build(BuildContext context) {
    return ConfirmDialog(
      title: 'Rejoin your game?',
      message: 'You still have a seat held at table $roomCode.',
      confirmLabel: 'Rejoin',
      cancelLabel: 'Discard',
      icon: Icons.history_rounded,
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
        Expanded(
          // Centred in whatever height the phone has, scrolling only if it
          // genuinely runs out.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(m.s(20), m.s(4), m.s(20), m.s(8)),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - m.s(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Hero(compact: false),
                    SizedBox(height: m.s(26)),
                    const _SectionLabel('Choose how to play'),
                    SizedBox(height: m.s(12)),
                    _Staggered(index: 0, child: _FeaturedMode(spec: playModes[0])),
                    SizedBox(height: m.s(12)),
                    _ModeTiles(specs: playModes.sublist(1), firstIndex: 1),
                    SizedBox(height: m.s(16)),
                  ],
                ),
              ),
            ),
          ),
        ),
        const _Footer(),
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
              const Expanded(flex: 40, child: Center(child: _Hero(compact: true))),
              Expanded(
                flex: 56,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(m.s(8), 0, m.s(28), m.s(6)),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SectionLabel('Choose how to play'),
                        SizedBox(height: m.s(8)),
                        _Staggered(
                          index: 0,
                          child: _FeaturedMode(spec: playModes[0], dense: true),
                        ),
                        SizedBox(height: m.s(10)),
                        _ModeTiles(specs: playModes.sublist(1), firstIndex: 1, dense: true),
                      ],
                    ),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return Row(
      children: [
        Container(
          width: m.s(3),
          height: m.s(14),
          decoration: BoxDecoration(
            gradient: goldButtonGradient,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        SizedBox(width: m.s(8)),
        Text(text, style: AppText.semiBold(m.s(13), AppColors.textSubtle)),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: m.s(10), top: m.s(4)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SuitGlyph(suit: Suit.spades, size: m.s(11), color: AppColors.textFaint),
          SizedBox(width: m.s(6)),
          Text(
            'Spades are trump · 3 or 5 hands',
            style: AppText.medium(m.s(11), AppColors.textFaint),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final settings = SettingsScope.of(context);
    final name = settings.playerName.trim();

    return Row(
      children: [
        GlassPill(
          radius: m.s(24),
          padding: EdgeInsets.fromLTRB(m.s(5), m.s(5), m.s(12), m.s(5)),
          border: AppColors.hairlineStrong,
          // The player's own name is the natural door to their profile.
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: m.s(32),
                    height: m.s(32),
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: goldButtonGradient,
                    ),
                    child: Text(
                      name.isEmpty ? '?' : name[0].toUpperCase(),
                      style: AppText.bold(m.s(14), AppColors.onGold),
                    ),
                  ),
                  Positioned(
                    right: -m.s(1),
                    bottom: -m.s(1),
                    child: Container(
                      width: m.s(10),
                      height: m.s(10),
                      decoration: BoxDecoration(
                        color: AppColors.success,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF061A14), width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(width: m.s(9)),
              Text(
                settings.playerName,
                style: AppText.semiBold(m.s(14), AppColors.textOnDark),
              ),
              SizedBox(width: m.s(4)),
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
            size: m.s(20),
            color: AppColors.textOnDark,
          ),
        ),
      ],
    );
  }
}

/// Three card backs fanned above the wordmark. They spread out of a single
/// stack when the screen opens, then drift very slowly — transform-only
/// motion on a cached layer, so it costs next to nothing to keep alive.
class _Hero extends StatefulWidget {
  const _Hero({required this.compact});

  final bool compact;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> with TickerProviderStateMixin {
  late final AnimationController _spread = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  )..repeat();

  @override
  void dispose() {
    _spread.dispose();
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final palette = SettingsScope.of(context).palette;
    final compact = widget.compact;
    final cardWidth = m.s(compact ? 62 : 78);
    final cardHeight = cardWidth * CardBackView.aspect;
    final fanWidth = m.s(compact ? 190 : 230);
    final fanHeight = cardHeight + m.s(compact ? 26 : 30);
    final card = RepaintBoundary(
      child: CardBackView(width: cardWidth, palette: palette, spadeEmblem: true),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: fanWidth,
          height: fanHeight,
          child: AnimatedBuilder(
            animation: Listenable.merge([_spread, _drift]),
            builder: (context, _) {
              final s = Curves.easeOutBack.transform(_spread.value);
              final phase = _drift.value * 2 * math.pi;
              Widget placed(int i) {
                final k = i - 1; // -1, 0, 1
                final bob = math.sin(phase + i * 1.3) * m.s(3);
                return Positioned(
                  left: fanWidth / 2 - cardWidth / 2 + k * cardWidth * 0.62 * s,
                  top: m.s(compact ? 14 : 16) + (k == 0 ? -m.s(8) : 0) * s + bob,
                  child: Transform.rotate(
                    angle: k * 0.24 * s + math.sin(phase + i) * 0.015,
                    alignment: Alignment.bottomCenter,
                    child: card,
                  ),
                );
              }

              return Stack(
                clipBehavior: Clip.none,
                children: [placed(0), placed(2), placed(1)],
              );
            },
          ),
        ),
        SizedBox(height: m.s(8)),
        GoldGradientText(
          'CALL BREAK',
          style: AppText.wordmark(m.s(compact ? 36 : 46)).copyWith(
            shadows: const [Shadow(color: Color(0x99000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
        ),
        SizedBox(height: m.s(2)),
        Text(
          'Bid. Break. Win.',
          style: AppText.medium(
            m.s(compact ? 14 : 15),
            AppColors.textSubtle,
            letterSpacing: m.s(compact ? 1.4 : 2),
          ),
        ),
      ],
    );
  }
}

/// A one-shot rise-and-fade, staggered by [index], for the mode cards.
class _Staggered extends StatelessWidget {
  const _Staggered({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + index * 90),
      curve: Motion.enter,
      child: child,
      builder: (context, t, child) {
        // Hold back the later cards for the first part of their run.
        final local = ((t * (1 + index * 0.25)) - index * 0.25).clamp(0.0, 1.0);
        return Opacity(
          opacity: local,
          child: Transform.translate(offset: Offset(0, 16 * (1 - local)), child: child),
        );
      },
    );
  }
}

/// The headline way in — solo against bots, which works with no connection
/// at all — as a wide card with a play button.
class _FeaturedMode extends StatelessWidget {
  const _FeaturedMode({required this.spec, this.dense = false});

  final PlayModeSpec spec;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final radius = BorderRadius.circular(m.s(18));

    return PressFeedback(
      onTap: () => startTable(context, spec.mode),
      scale: 0.97,
      child: Container(
        padding: EdgeInsets.all(m.s(dense ? 14 : 16)),
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              spec.accent.withValues(alpha: 0.32),
              const Color(0xCC061A14),
            ],
          ),
          border: Border.all(color: spec.accent.withValues(alpha: 0.55)),
          boxShadow: [
            ...AppShadows.low,
            ...AppShadows.glow(spec.accent, strength: 0.5, blur: 24),
          ],
        ),
        child: Row(
          children: [
            _ModeIcon(spec: spec, size: m.s(dense ? 44 : 52)),
            SizedBox(width: m.s(14)),
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
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bold(m.s(dense ? 16 : 18), AppColors.textPrimary),
                        ),
                      ),
                      SizedBox(width: m.s(8)),
                      _ModeBadge(spec: spec),
                    ],
                  ),
                  SizedBox(height: m.s(3)),
                  Text(
                    spec.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.medium(m.s(12.5), AppColors.textMuted),
                  ),
                ],
              ),
            ),
            SizedBox(width: m.s(10)),
            Container(
              width: m.s(dense ? 40 : 46),
              height: m.s(dense ? 40 : 46),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: goldButtonGradient,
                boxShadow: AppShadows.glow(AppColors.goldDeep, strength: 0.9, blur: 14),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                size: m.s(dense ? 24 : 28),
                color: AppColors.onGold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The other three modes, side by side as square tiles.
class _ModeTiles extends StatelessWidget {
  const _ModeTiles({required this.specs, required this.firstIndex, this.dense = false});

  final List<PlayModeSpec> specs;
  final int firstIndex;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < specs.length; i++) ...[
            Expanded(
              child: _Staggered(
                index: firstIndex + i,
                child: _ModeTile(spec: specs[i], dense: dense),
              ),
            ),
            if (i < specs.length - 1) SizedBox(width: m.s(10)),
          ],
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.spec, this.dense = false});

  final PlayModeSpec spec;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final radius = BorderRadius.circular(m.s(16));

    return PressFeedback(
      onTap: () => startTable(context, spec.mode),
      scale: 0.95,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              spec.accent.withValues(alpha: 0.2),
              const Color(0xB3061A14),
            ],
          ),
          border: Border.all(color: spec.accent.withValues(alpha: 0.42)),
          boxShadow: AppShadows.low,
        ),
        child: Stack(
          children: [
            // A large faint glyph in the corner gives the tile depth.
            Positioned(
              right: -m.s(10),
              bottom: -m.s(12),
              child: Icon(
                spec.icon,
                size: m.s(dense ? 54 : 64),
                color: spec.accent.withValues(alpha: 0.1),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(m.s(dense ? 10 : 12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ModeIcon(spec: spec, size: m.s(dense ? 30 : 36)),
                  SizedBox(height: m.s(dense ? 8 : 10)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      spec.name,
                      style: AppText.bold(m.s(14), AppColors.textPrimary),
                    ),
                  ),
                  SizedBox(height: m.s(4)),
                  _ModeBadge(spec: spec),
                  if (!dense) ...[
                    SizedBox(height: m.s(6)),
                    Text(
                      spec.subtitle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.medium(m.s(10.5), AppColors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeIcon extends StatelessWidget {
  const _ModeIcon({required this.spec, required this.size});

  final PlayModeSpec spec;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            spec.accent.withValues(alpha: 0.42),
            spec.accent.withValues(alpha: 0.16),
          ],
        ),
        border: Border.all(color: spec.accent.withValues(alpha: 0.7)),
      ),
      child: Icon(spec.icon, size: size * 0.52, color: Colors.white),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.spec});

  final PlayModeSpec spec;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: m.s(7), vertical: m.s(2)),
      decoration: BoxDecoration(
        color: spec.accent.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(m.s(8)),
      ),
      child: Text(spec.badge, style: AppText.semiBold(m.s(9.5), spec.accent)),
    );
  }
}

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
