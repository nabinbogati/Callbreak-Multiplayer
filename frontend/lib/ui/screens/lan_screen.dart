import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/game.dart';
import '../../net/lan_discovery.dart';
import '../../net/lan_host_session.dart';
import '../../net/remote_session.dart';
import '../../net/session.dart';
import '../../state/app_settings.dart';
import '../widgets/backdrop.dart';
import '../widgets/fields.dart';
import '../widgets/pulse_ripple.dart';
import 'table_screen.dart';

/// Same tiny room-code helper `settings_sheet.dart` uses elsewhere —
/// reimplemented locally rather than shared, since that file is out of scope
/// here.
String _newRoomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random();
  return List.generate(4, (_) => alphabet[random.nextInt(alphabet.length)]).join();
}

/// Fully self-hosted LAN play: browse for games broadcasting on the local
/// Wi‑Fi, join one, or host your own table for others to find.
class LanScreen extends StatefulWidget {
  const LanScreen({super.key});

  @override
  State<LanScreen> createState() => _LanScreenState();
}

class _LanScreenState extends State<LanScreen> {
  LanDiscovery? _discovery;
  LanHostSession? _hostSession;
  bool _hostSessionHandedOff = false;

  /// The room code the Host tab displays and that hosting uses, generated once
  /// per LAN screen so the code the host shares is the code that starts.
  late final String _roomCode = _newRoomCode();

  @override
  void initState() {
    super.initState();
    _startBrowsing();
  }

  void _startBrowsing() {
    final discovery = LanDiscovery()..addListener(_onChanged);
    _discovery = discovery;
    discovery.start();
  }

  void _stopBrowsing() {
    final discovery = _discovery;
    if (discovery == null) return;
    discovery.removeListener(_onChanged);
    discovery.stop();
    discovery.dispose();
    _discovery = null;
  }

  void _onChanged() => setState(() {});

  Future<void> _startHosting() async {
    _stopBrowsing();
    final settings = SettingsScope.of(context);
    final hostSession = LanHostSession(
      playerName: settings.playerName,
      roomCode: _roomCode,
      difficulty: settings.difficulty,
      animationSpeed: settings.animationSpeed,
      // Quickplay (3 hands) is the default everywhere else the length is
      // asked, so a LAN table opens on it too rather than on the engine's
      // full-match default.
      handsPerGame: 3,
    )..addListener(_onChanged);
    setState(() => _hostSession = hostSession);
    await hostSession.startHosting();
    if (!mounted) return;

    // Hosting runs on its own full-screen lobby, exactly like a private
    // table. Once that lobby is closed — Leave, or back from the finished
    // game — the LAN sheet is done too.
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (pageContext) => LanHostLobbyScreen(
          session: hostSession,
          onStart: _launchHostedGame,
          onLeave: () => Navigator.of(pageContext).pop(),
          onHandsChange: _setHostHands,
        ),
      ),
    );
    if (!mounted) return;
    if (!_hostSessionHandedOff) _cancelHosting();
    navigator.pop();
  }

  void _cancelHosting() {
    final hostSession = _hostSession;
    if (hostSession == null) return;
    hostSession.removeListener(_onChanged);
    hostSession.dispose();
    setState(() => _hostSession = null);
    _startBrowsing();
  }

  /// The host's Quickplay/Normal Play pick, live until the game deals. The
  /// setter notifies listeners, so the full-screen lobby rebuilds.
  void _setHostHands(int hands) {
    final hostSession = _hostSession;
    if (hostSession == null) return;
    hostSession.handsPerGame = hands;
  }

  void _launchHostedGame() {
    final hostSession = _hostSession;
    if (hostSession == null) return;
    hostSession.startGame();
    _hostSessionHandedOff = true;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => TableScreen(session: hostSession)))
        .then((_) {
          // Back from the table: this LanScreen instance is done either way.
          if (mounted) Navigator.of(context).maybePop();
        });
  }

  void _joinGame(LanGameAdvert advert) {
    final settings = SettingsScope.of(context);
    final session = RemoteSession(
      serverUrl: advert.wsUrl,
      roomCode: advert.roomCode,
      playerName: settings.playerName,
      mode: GameMode.lan,
      deviceId: settings.identity.deviceId,
    );
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => TableScreen(session: session)));
  }

  @override
  void dispose() {
    _stopBrowsing();
    if (!_hostSessionHandedOff) _hostSession?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _LanBody(
      roomCode: _roomCode,
      discovery: _discovery,
      onHost: _startHosting,
      onJoin: _joinGame,
    );
  }
}

// -------------------------------------------------------------------- body
//
// Single unified body for both browsing/joining and hosting: one page shell
// (top bar + scrollable list) throughout. The "Host a game" card at the top
// of the list turns into the live hosting summary (room code + player list)
// once hosting starts, rather than swapping to a different page/widget.

class _LanBody extends StatefulWidget {
  const _LanBody({
    required this.roomCode,
    required this.discovery,
    required this.onHost,
    required this.onJoin,
  });

  /// The code the Host tab shows and that hosting will use.
  final String roomCode;

  final LanDiscovery? discovery;
  final VoidCallback onHost;
  final ValueChanged<LanGameAdvert> onJoin;

  @override
  State<_LanBody> createState() => _LanBodyState();
}

class _LanBodyState extends State<_LanBody> {
  /// Which LAN tab is showing — Host by default, like Private defaults to
  /// Create.
  bool _hostTab = true;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final games = widget.discovery?.games ?? const <LanGameAdvert>[];

    // Mirrors the private join sheet: a Host/Join tab toggle at the top, with
    // the matching panel below. Content-sized so the popup stays compact —
    // the games list is a bounded box inside rather than stretching the
    // window to fill the screen.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(m.sc(20, 16), m.sc(8, 4), m.sc(20, 16), 0),
            child: _TopBar(title: 'LAN Play'),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(m.sc(20, 16), m.sc(14, 10), m.sc(20, 16), 0),
            child: Row(
              children: [
                Expanded(
                  child: _LanTab(
                    label: 'Host',
                    selected: _hostTab,
                    onTap: () => setState(() => _hostTab = true),
                  ),
                ),
                SizedBox(width: m.sc(10, 8)),
                Expanded(
                  child: _LanTab(
                    label: 'Join',
                    selected: !_hostTab,
                    onTap: () => setState(() => _hostTab = false),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: m.sc(16, 12)),
          if (_hostTab)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: m.sc(20, 16)),
              child: _HostTab(
                roomCode: widget.roomCode,
                onHost: widget.onHost,
              ),
            )
          else
            _JoinTab(
              games: games,
              onJoin: widget.onJoin,
            ),
          SizedBox(height: m.s(6)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- tabs
//
// The LAN popup mirrors the private join sheet: a Host/Join toggle on top
// with the matching panel below. Both panels are compact and content-sized,
// so the popup stays small and nothing needs scrolling for basic actions.

/// The full-screen hosting lobby, opened when the host presses "Host game" —
/// the same room-code/seats/match-length/Start lobby a private table shows.
class LanHostLobbyScreen extends StatelessWidget {
  const LanHostLobbyScreen({
    super.key,
    required this.session,
    required this.onStart,
    required this.onLeave,
    required this.onHandsChange,
  });

  final LanHostSession session;
  final VoidCallback onStart;
  final VoidCallback onLeave;
  final ValueChanged<int> onHandsChange;

  @override
  Widget build(BuildContext context) {
    final palette = SettingsScope.of(context).palette;

    // Listen to the host session so the match-length pick and the seat list
    // stay live — changing Quickplay/Normal Play or a guest joining must
    // rebuild this lobby without needing a server round-trip.
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = session;
        return Scaffold(
          body: MetricsScope(
            builder: (context) {
              final m = Metrics.of(context);
              // LobbyPanel brings its own centring/scroll/padding — wrapping
              // it again here would double the padding and squeeze the layout.
              return Backdrop(
                colors: palette.background,
                glow: palette.glow,
                horizontal: !m.isPortrait,
                child: SafeArea(
                  child: LobbyPanel(
                    lobby: LobbyState(
                      roomCode: s.roomCode,
                      isOnline: false,
                      seats: [
                        for (final p in s.lobbyPlayers)
                          LobbySeat(
                            seat: p.seat,
                            name: p.name,
                            isBot: p.kind == PlayerKind.bot,
                            connected: p.connected,
                            isYou: p.seat == LanHostSession.hostSeat,
                            isHost: p.seat == LanHostSession.hostSeat,
                          ),
                      ],
                      isHost: true,
                      canStart: s.canStart,
                      humansSeated: s.lobbyPlayers
                          .where((p) => p.connected)
                          .length,
                      minPlayers: 2,
                      handsPerGame: s.handsPerGame,
                    ),
                    countdown: null,
                    onStart: onStart,
                    onLeave: onLeave,
                    onHandsChange: onHandsChange,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _LanTab extends StatelessWidget {
  const _LanTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPill(
      radius: m.sc(12, 9),
      onTap: onTap,
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(16, 12),
        vertical: m.sc(14, 9),
      ),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: SizedBox(
        width: double.infinity,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppText.bold(
            m.sc(14, 12),
            selected ? AppColors.onGold : AppColors.textOnDark,
          ),
        ),
      ),
    );
  }
}

/// The Host panel: the code this device will host on, plus the button that
/// starts hosting. Pressing it opens the full-screen hosting lobby.
class _HostTab extends StatelessWidget {
  const _HostTab({required this.roomCode, required this.onHost});

  final String roomCode;
  final VoidCallback onHost;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Game code',
          style: AppText.semiBold(m.sc(13, 11), AppColors.textMuted),
        ),
        SizedBox(height: m.s(8)),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: m.sc(14, 9)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.panel,
            border: Border.all(
              color: AppColors.goldBorder.withValues(alpha: 0.4),
            ),
            borderRadius: BorderRadius.circular(m.sc(12, 9)),
          ),
          child: GoldGradientText(
            roomCode,
            style: AppText.bold(
              m.sc(24, 20),
              AppColors.gold,
              letterSpacing: m.sc(4, 2),
            ),
          ),
        ),
        SizedBox(height: m.s(16)),
        _PrimaryButton(label: 'Host game', onTap: onHost),
      ],
    );
  }
}

/// The Join panel: the discovered games list. Every game component carries its
/// own code input and Join button, so joining is one tap per row. The list
/// grows with however many games are broadcasting, capped so the tab stays the
/// same size as the Host tab.
class _JoinTab extends StatelessWidget {
  const _JoinTab({required this.games, required this.onJoin});

  final List<LanGameAdvert> games;
  final ValueChanged<LanGameAdvert> onJoin;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.sc(20, 16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Games on your Wi‑Fi',
            style: AppText.semiBold(m.sc(13, 11), AppColors.textMuted),
          ),
          SizedBox(height: m.s(8)),
          // Sized to content (grows as games appear) but capped so the tab
          // stays the same size as the Host tab.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: m.sc(280, 200)),
            child: games.isEmpty
                ? const _SearchingState()
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: games.length,
                    separatorBuilder: (_, _) => SizedBox(height: m.s(8)),
                    itemBuilder: (_, i) =>
                        _GameRow(advert: games[i], onJoin: onJoin),
                  ),
          ),
        ],
      ),
    );
  }
}


class _SearchingState extends StatelessWidget {
  const _SearchingState();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: m.sc(24, 12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          // Expanding radar rings rather than a spinner: the motion says
          // "still looking out there" while the broadcast sweeps the Wi‑Fi.
          PulseRipple(
            size: m.sc(54, 44),
            ringCount: 2,
            child: Container(
              width: m.sc(28, 22),
              height: m.sc(28, 22),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.gold.withValues(alpha: 0.14),
                border: Border.all(
                  color: AppColors.goldBorder.withValues(alpha: 0.6),
                ),
              ),
              child: Icon(
                Icons.radar_rounded,
                size: m.sc(15, 12),
                color: AppColors.gold,
              ),
            ),
          ),
          SizedBox(height: m.sc(12, 8)),
          Text(
            'Searching for games on your Wi‑Fi…',
            textAlign: TextAlign.center,
            style: AppText.medium(m.sc(12, 11), AppColors.textMuted),
          ),
        ],
      ),
      ),
    );
  }
}

/// One discovered game: the host's table plus its own code input and Join
/// button, so every available-game component is self-contained.
class _GameRow extends StatefulWidget {
  const _GameRow({required this.advert, required this.onJoin});

  final LanGameAdvert advert;
  final ValueChanged<LanGameAdvert> onJoin;

  @override
  State<_GameRow> createState() => _GameRowState();
}

class _GameRowState extends State<_GameRow> {
  // Deliberately empty: the room code is never auto-filled or shown — the
  // player enters the code the host shared, and Join only works with it.
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the game code');
      return;
    }
    if (code != widget.advert.roomCode.toUpperCase()) {
      setState(() => _error = 'That code does not match this game.');
      return;
    }
    setState(() => _error = null);
    widget.onJoin(widget.advert);
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final advert = widget.advert;

    return Container(
      padding: EdgeInsets.all(m.sc(10, 8)),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.hairlineStrong),
        borderRadius: BorderRadius.circular(m.sc(12, 10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: m.sc(34, 26),
                height: m.sc(34, 26),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.gold.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(m.sc(10, 8)),
                ),
                child: Text(
                  advert.hostName.isEmpty ? '?' : advert.hostName[0].toUpperCase(),
                  style: AppText.bold(m.sc(14, 12), AppColors.gold),
                ),
              ),
              SizedBox(width: m.sc(10, 8)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "${advert.hostName}'s table",
                      style: AppText.semiBold(m.sc(13, 12), AppColors.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: m.sc(2, 1)),
                    Text(
                      '${advert.playerCount}/${advert.maxPlayers} players',
                      style: AppText.medium(m.sc(11, 10), AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: m.s(6)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  inputFormatters: [LengthLimitingTextInputFormatter(4)],
                  style: AppText.bold(
                    m.sc(16, 14),
                    AppColors.gold,
                    letterSpacing: m.sc(2, 1.5),
                  ),
                  decoration: fieldDecoration(m, 'ABCD'),
                ),
              ),
              SizedBox(width: m.sc(8, 6)),
              GlassPill(
                radius: m.sc(10, 9),
                onTap: _submit,
                padding: EdgeInsets.symmetric(
                  horizontal: m.sc(16, 12),
                  vertical: m.sc(10, 8),
                ),
                background: AppColors.gold,
                border: AppColors.gold,
                child: Text(
                  'Join',
                  style: AppText.semiBold(m.sc(12, 11), AppColors.onGold),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            SizedBox(height: m.s(5)),
            Text(
              _error!,
              style: AppText.medium(m.sc(11, 10), AppColors.danger),
            ),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ shared

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      children: [
        Text(title, style: AppText.bold(m.sc(16, 14), AppColors.textPrimary)),
      ],
    );
  }
}

/// The host's Quickplay/Normal Play choice is now the shared [LobbyPanel]
/// match-length picker, so it is not reimplemented here.

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return SizedBox(
      width: double.infinity,
      child: PressFeedback(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(vertical: m.sc(15, 10)),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [AppColors.gold, AppColors.goldDeep]),
            borderRadius: BorderRadius.circular(m.sc(14, 11)),
          ),
          child: Text(label, style: AppText.bold(m.sc(15, 13), AppColors.onGold)),
        ),
      ),
    );
  }
}
