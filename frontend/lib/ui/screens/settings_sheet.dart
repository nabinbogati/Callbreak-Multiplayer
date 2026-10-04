import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/game.dart';
import '../../net/remote_session.dart' show kQuickplayRoom;
import '../../net/session.dart';
import '../../state/app_settings.dart';
import '../widgets/backdrop.dart';
import '../widgets/buttons.dart';
import '../widgets/fields.dart';
import '../widgets/playing_card_view.dart';

/// Drops the on-screen keyboard when the user taps anywhere outside a focused
/// text field. Flutter's default only does this for touch platforms
/// (Android/iOS); on desktop and web it is a no-op, so it is wired explicitly
/// for every field.
///
/// Unlike wrapping the screen in a tap-catching `GestureDetector`, firing from
/// `onTapOutside` does not fight the tap's own gesture for the arena — the
/// widget under the finger still gets its tap, so buttons work and the
/// keyboard still goes away.
void _dismissKeyboard(PointerDownEvent _) {
  FocusManager.instance.primaryFocus?.unfocus();
}

/// Where to connect and which table to sit at.
class JoinDetails {
  const JoinDetails({
    this.serverUrl = '',
    this.roomCode = '',
    this.handsPerGame,
    this.creating = false,
  });

  final String serverUrl;
  final String roomCode;

  /// Only meaningful on the sheets that ask: `3` (Quickplay) or `5` (Normal
  /// Play) for Online and Private, and the same choice for a solo bot game.
  /// Null for LAN, which never deals from this sheet — the host picks the
  /// length on the LAN screen instead.
  final int? handsPerGame;

  /// True when this join is meant to open a brand-new room — Private mode's
  /// "Create" flow. Joins carry false, so a mistyped room code is reported as
  /// "room does not exist" instead of silently opening an empty room nobody
  /// can find again.
  final bool creating;
}

/// Hosts any of this screen's sheets in the standard bottom-sheet chrome —
/// portrait a bottom sheet, landscape a centered bounded panel. Public so the
/// compact on-table settings panel opens with the exact same framing.
Future<T?> showSheet<T>(BuildContext context, WidgetBuilder builder) {
  final palette = SettingsScope.of(context).palette;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => SheetFrame(
      palette: palette,
      child: Builder(builder: builder),
    ),
  );
}

/// Anchors a bottom sheet without letting it swallow the whole screen in
/// landscape: portrait keeps the sheet pinned to the bottom edge (rounded top
/// corners), landscape floats it as a centered panel with a bounded width and
/// height so it never runs past the app's screens. Safe-area insets are
/// applied around the whole panel, so a landscape notch shaves the frame
/// symmetrically instead of padding the content from one edge unevenly.
class SheetFrame extends StatelessWidget {
  const SheetFrame({super.key, required this.palette, required this.child});

  final ThemePalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // The sheet is laid out in a route that spans the full screen, so the
    // keyboard never shrinks it — whatever part of that space sits behind the
    // keys is invisible, and worse in landscape where the keys eat half the
    // height. Size and anchor against the *visible* remainder instead: reserve
    // the inset below the panel so a focused text field is never hidden.
    final availableHeight = MediaQuery.sizeOf(context).height - keyboard;
    final maxHeight = availableHeight * (m.isPortrait ? 1.0 : 0.92);
    final maxWidth = m.isPortrait ? double.infinity : m.sc(520, 560);

    // The panels are small windows floating over the table, and the whole
    // sheet route is `isScrollControlled`, so its content covers the entire
    // screen. That full-screen content layer swallows every tap — including
    // ones outside the panel — which is why showModalBottomSheet's own barrier
    // never gets to dismiss the sheet here. Re-add that dismissal behind the
    // panel: a transparent [ModalBarrier] that pops the sheet when the dim
    // area around the panel is tapped, while taps on the panel still land on
    // the panel.
    return Stack(
      children: [
        ModalBarrier(
          color: Colors.transparent,
          dismissible: true,
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: Align(
              alignment: m.isPortrait ? Alignment.bottomCenter : Alignment.center,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
                child: Material(
                  color: palette.tableBackground.last,
                  shape: RoundedRectangleBorder(
                    // Portrait keeps the sheet flush to the bottom, so only the top
                    // corners round; landscape floats free and rounds all four.
                    borderRadius: m.isPortrait
                        ? const BorderRadius.vertical(top: Radius.circular(24))
                        : BorderRadius.circular(m.sc(20, 16)),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- preferences

Future<void> showSettingsSheet(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
  );
}

/// The tabbed sections of the settings sheet. [debug] only exists in debug
/// builds — release trees keep it to profile + gameplay, so developer tooling
/// never leaks to players.
enum _SettingsTab { profile, gameplay, debug }

extension _SettingsTabX on _SettingsTab {
  String get label => switch (this) {
    _SettingsTab.profile => 'Profile',
    _SettingsTab.gameplay => 'Gameplay',
    _SettingsTab.debug => 'Debug',
  };
}

/// The settings as a full-screen page: backdrop chrome, a back button, the
/// tab pills and a scrolling pane. Being a full page, it is always one size —
/// switching Profile/Gameplay/Debug never resizes anything.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Built in didChangeDependencies (not as lazy `late final` initializers,
  // and not in initState — SettingsScope.of() needs an InheritedWidget
  // lookup, which Flutter forbids before initState() has completed) so both
  // are always constructed while mounted. In a release build, kDebugMode is
  // false and the debug section below is never rendered, so `_debugServer`
  // would otherwise never be touched during build() — its first access
  // would land in dispose(), which crashes because the element is
  // deactivating by then.
  late final TextEditingController _name;
  late final TextEditingController _debugServer;
  bool _controllersReady = false;

  static const _debugTabs = [
    _SettingsTab.profile,
    _SettingsTab.gameplay,
    _SettingsTab.debug,
  ];
  static const _releaseTabs = [_SettingsTab.profile, _SettingsTab.gameplay];

  List<_SettingsTab> get _tabs => kDebugMode ? _debugTabs : _releaseTabs;

  _SettingsTab _tab = _SettingsTab.profile;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllersReady) return;
    _controllersReady = true;
    final settings = SettingsScope.of(context);
    _name = TextEditingController(text: settings.playerName);
    _debugServer = TextEditingController(text: settings.serverUrl);
  }

  @override
  void dispose() {
    _name.dispose();
    _debugServer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = SettingsScope.of(context).palette;

    return Scaffold(
      body: MetricsScope(
        builder: (context) {
          final m = Metrics.of(context);
          return Backdrop(
            colors: palette.background,
            glow: palette.glow,
            horizontal: !m.isPortrait,
            child: SafeArea(
              child: Column(
                children: [
                  // Back button + title.
                  Padding(
                    padding: EdgeInsets.fromLTRB(m.s(16), m.s(8), m.s(16), 0),
                    child: Row(
                      children: [
                        GlassPill(
                          radius: m.sc(16, 15),
                          padding: EdgeInsets.all(m.sc(8, 9)),
                          border: AppColors.hairlineStrong,
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Icon(
                            Icons.arrow_back_rounded,
                            size: m.sc(16, 19),
                            color: AppColors.textOnDark,
                          ),
                        ),
                        SizedBox(width: m.s(12)),
                        Text(
                          'Settings',
                          style: AppText.bold(m.sc(18, 16), AppColors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                  // Tab pills stay pinned; only the active pane scrolls.
                  Padding(
                    padding: EdgeInsets.fromLTRB(m.s(20), m.s(14), m.s(20), 0),
                    child: Row(
                      children: [
                        for (var i = 0; i < _tabs.length; i++) ...[
                          Expanded(
                            child: _TabPill(
                              label: _tabs[i].label,
                              selected: _tab == _tabs[i],
                              onTap: () => setState(() => _tab = _tabs[i]),
                            ),
                          ),
                          if (i < _tabs.length - 1) SizedBox(width: m.s(8)),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: m.s(6)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(m.s(20), m.s(16), m.s(20), m.s(20)),
                      child: _buildPane(m, _tab),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPane(Metrics m, _SettingsTab tab) {
    final settings = SettingsScope.of(context);
    return switch (tab) {
      _SettingsTab.profile => _buildProfilePane(m, settings),
      _SettingsTab.gameplay => _buildGameplayPane(m, settings),
      _SettingsTab.debug => _buildDebugPane(m, settings),
    };
  }

  // ---------------------------------------------------------------- profile

  Widget _buildProfilePane(Metrics m, AppSettings settings) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Label('Display name'),
        SizedBox(height: m.s(8)),
        TextField(
          controller: _name,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.words,
          onTapOutside: _dismissKeyboard,
          style: AppText.semiBold(m.s(14), AppColors.textPrimary),
          decoration: fieldDecoration(m, 'Your name'),
          onChanged: (value) => settings.playerName = value,
        ),
        SizedBox(height: m.s(18)),
        _Label('Table colour'),
        SizedBox(height: m.s(10)),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final theme in TableTheme.values) ...[
              _ThemeSwatch(
                theme: theme,
                selected: settings.theme == theme,
                onTap: () => setState(() => settings.theme = theme),
              ),
              SizedBox(width: m.s(12)),
            ],
          ],
        ),
        SizedBox(height: m.s(18)),
        _Label('Card colour'),
        SizedBox(height: m.s(10)),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: m.s(12),
          runSpacing: m.s(12),
          children: [
            for (final style in CardStyle.values)
              _CardSwatch(
                style: style,
                selected: settings.cardStyle == style,
                onTap: () => setState(() => settings.cardStyle = style),
              ),
          ],
        ),
        SizedBox(height: m.s(16)),
        _CardPreview(
          width: m.s(52),
          cards: const [
            PlayingCard(14, Suit.spades),
            PlayingCard(13, Suit.hearts),
          ],
        ),
        SizedBox(height: m.s(8)),
        _Label(CardFacePalette.of(settings.cardStyle).label),
      ],
    );
  }

  // --------------------------------------------------------------- gameplay

  Widget _buildGameplayPane(Metrics m, AppSettings settings) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SettingRow(
          label: 'Bot difficulty',
          children: [
            for (final level in BotDifficulty.values)
              _ChoiceChip(
                label: level.name[0].toUpperCase() + level.name.substring(1),
                selected: settings.difficulty == level,
                onTap: () => setState(() => settings.difficulty = level),
              ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Drag to play',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.dragToPlayEnabled,
              onTap: () => setState(() => settings.dragToPlayEnabled = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.dragToPlayEnabled,
              onTap: () => setState(() => settings.dragToPlayEnabled = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Tap twice to play',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.tapTwiceToPlay,
              onTap: () => setState(() => settings.tapTwiceToPlay = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.tapTwiceToPlay,
              onTap: () => setState(() => settings.tapTwiceToPlay = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Auto throw last card',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.autoThrowLastCard,
              onTap: () => setState(() => settings.autoThrowLastCard = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.autoThrowLastCard,
              onTap: () => setState(() => settings.autoThrowLastCard = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Auto throw last suit card',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.autoThrowLastSuitCard,
              onTap: () => setState(() => settings.autoThrowLastSuitCard = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.autoThrowLastSuitCard,
              onTap: () => setState(() => settings.autoThrowLastSuitCard = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Background music',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.musicEnabled,
              onTap: () => setState(() => settings.musicEnabled = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.musicEnabled,
              onTap: () => setState(() => settings.musicEnabled = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Sound effects',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.sfxEnabled,
              onTap: () => setState(() => settings.sfxEnabled = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.sfxEnabled,
              onTap: () => setState(() => settings.sfxEnabled = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Vibration',
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.hapticsEnabled,
              onTap: () => setState(() => settings.hapticsEnabled = true),
            ),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.hapticsEnabled,
              onTap: () => setState(() => settings.hapticsEnabled = false),
            ),
          ],
        ),
        SizedBox(height: m.s(14)),
        _SettingRow(
          label: 'Animation speed',
          children: [
            for (final speed in AnimationSpeed.values)
              _ChoiceChip(
                label: speed.name[0].toUpperCase() + speed.name.substring(1),
                selected: settings.animationSpeed == speed,
                onTap: () => setState(() => settings.animationSpeed = speed),
              ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ debug

  Widget _buildDebugPane(Metrics m, AppSettings settings) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Label('Developer'),
        SizedBox(height: m.s(8)),
        TextField(
          controller: _debugServer,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onTapOutside: _dismissKeyboard,
          style: AppText.semiBold(m.s(14), AppColors.textPrimary),
          decoration: fieldDecoration(m, 'Override server (debug only)'),
          onChanged: (value) => settings.serverUrl = value,
        ),
        SizedBox(height: m.s(18)),
        _Label('Debug mode'),
        SizedBox(height: m.s(10)),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ChoiceChip(
              label: 'On',
              selected: settings.debugMode,
              onTap: () => setState(() => settings.debugMode = true),
            ),
            SizedBox(width: m.s(8)),
            _ChoiceChip(
              label: 'Off',
              selected: !settings.debugMode,
              onTap: () => setState(() => settings.debugMode = false),
            ),
          ],
        ),
        SizedBox(height: m.s(10)),
        // Arming Debug mode puts a clickable "Go offline" button on the
        // gameplay page (at a networked table). It lives on the table, not
        // here — this sheet is never open while a table is playing.
        Text(
          'Shows a "Go offline" button on networked tables.',
          textAlign: TextAlign.center,
          style: AppText.medium(m.s(11), AppColors.textMuted),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- join room

Future<JoinDetails?> showJoinSheet(
  BuildContext context, {
  required GameMode mode,
}) {
  return showSheet<JoinDetails>(
    context,
    (sheetContext) => _JoinBody(mode: mode),
  );
}

class _JoinBody extends StatefulWidget {
  const _JoinBody({required this.mode});

  final GameMode mode;

  @override
  State<_JoinBody> createState() => _JoinBodyState();
}

class _JoinBodyState extends State<_JoinBody> {
  // Built in didChangeDependencies (not as lazy `late final` initializers,
  // and not in initState — SettingsScope.of() needs an InheritedWidget
  // lookup, which Flutter forbids before initState() has completed) so both
  // are always constructed while the widget is mounted. Private mode never
  // actually reads `_server` during build() (only the standard server/room
  // flow does) — as a lazy field, its first access would otherwise happen
  // from dispose(), which crashes because the element is deactivating by
  // then and SettingsScope.of(context) can't look up an ancestor at that
  // point.
  late final TextEditingController _server;
  late final TextEditingController _room;
  bool _controllersReady = false;

  /// Private mode only: whether the "Create" or "Join" flow is showing.
  /// Create is the default entry point since it's the more common reason to
  /// open Private mode fresh.
  bool _creating = true;

  /// Quickplay/Normal Play selection: how many hands the match will run.
  /// Quickplay (3) is the default across every mode — it reads as the natural
  /// entry point, and players who want the full game pick Normal Play (5).
  late int _handsPerGame;

  /// Inline validation feedback, shown above the primary button. Set when the
  /// user presses it with a required field empty, so a dead-feeling button
  /// says what it was missing instead of doing nothing.
  String? _error;

  void _setError(String message) => setState(() => _error = message);

  void _clearError() => setState(() => _error = null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllersReady) return;
    _controllersReady = true;
    _handsPerGame = 3;
    final settings = SettingsScope.of(context);
    _server = TextEditingController(
      text: settings.serverUrl.isEmpty ? kDefaultServerUrl : settings.serverUrl,
    );
    _room = TextEditingController();
    if (widget.mode == GameMode.private) {
      _room.text = _newCode();
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _room.dispose();
    super.dispose();
  }

  String _newCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random();
    return List.generate(
      4,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  void _enterCreate() {
    setState(() {
      _creating = true;
      _room.text = _newCode();
      _error = null;
    });
  }

  void _enterJoin() {
    setState(() {
      _creating = false;
      _room.text = '';
      _error = null;
    });
  }

  String get _hint => switch (widget.mode) {
    GameMode.private =>
      _creating
          ? 'Share the room code with your friends. Empty seats are '
                'filled with bots when the host starts.'
          : 'Enter the room code a friend shared with you.',
    GameMode.lan =>
      'Point this at the host device on your Wi‑Fi, e.g. '
          'ws://192.168.1.20:8080',
    GameMode.online =>
      'Connects to the matchmaking server. Pick how long you want to play.',
    GameMode.bots => 'Pick how long you want to play.',
  };

  void _submit() {
    if (widget.mode == GameMode.bots) {
      Navigator.of(context).pop(
        JoinDetails(handsPerGame: _handsPerGame),
      );
      return;
    }

    if (widget.mode == GameMode.private) {
      final room = _room.text.trim().toUpperCase();
      if (room.isEmpty) {
        // The code only turns up empty in Join mode — Create ships prefilled.
        _setError(
          _creating
              ? 'Pick a room code and share it with your friends.'
              : 'Type the room code your friend shared.',
        );
        return;
      }
      Navigator.of(context).pop(
        JoinDetails(
          serverUrl: SettingsScope.of(context).effectiveServerUrl,
          roomCode: room,
          creating: _creating,
          // The creator opens the table on Quickplay, the same default every
          // other mode starts from — the server's own fallback is the full
          // game, so leaving this out would land the lobby on Normal Play.
          // Only the creating side sends it: joining an existing room plays
          // whatever length that room was created with, and the host can still
          // change it in the lobby before the deal.
          handsPerGame: _creating ? _handsPerGame : null,
        ),
      );
      return;
    }

    final server = _server.text.trim();
    if (server.isEmpty) {
      _setError('Enter a server address, like ws://192.168.1.20:8080.');
      return;
    }

    if (widget.mode == GameMode.online) {
      Navigator.of(context).pop(
        JoinDetails(
          serverUrl: server,
          roomCode: kQuickplayRoom,
          handsPerGame: _handsPerGame,
        ),
      );
      return;
    }

    final room = _room.text.trim().toUpperCase();
    if (room.isEmpty) {
      _setError('Type a room code and try again.');
      return;
    }
    Navigator.of(context).pop(JoinDetails(serverUrl: server, roomCode: room));
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final isPrivate = widget.mode == GameMode.private;

    // Sizes to its content so every field and button is visible without
    // scrolling; only if the form outgrows the sheet's available height does
    // it scroll as a fallback.
    return SingleChildScrollView(
      padding: EdgeInsets.all(m.sc(20, 14)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.mode.label,
            style: AppText.bold(m.sc(18, 14), AppColors.textPrimary),
          ),
          SizedBox(height: m.sc(6, 4)),
          Text(
            _hint,
            style: AppText.medium(m.sc(12, 11), AppColors.textMuted),
          ),
          SizedBox(height: m.sc(18, 10)),
          if (isPrivate)
            ..._privateFields(m)
          else if (widget.mode == GameMode.online)
            ..._onlineFields(m)
          else if (widget.mode == GameMode.bots)
            ..._botsFields(m)
          else
            ..._standardFields(m),
          if (_error != null) ...[
            SizedBox(height: m.sc(12, 8)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: m.sc(14, 12),
                  color: AppColors.danger,
                ),
                SizedBox(width: m.sc(6, 4)),
                Expanded(
                  child: Text(
                    _error!,
                    style: AppText.medium(m.sc(11.5, 10.5), AppColors.danger),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: m.sc(22, 12)),
          _PrimaryButton(
            label: switch (widget.mode) {
              GameMode.private => _creating ? 'Create room' : 'Join room',
              GameMode.bots => 'Start game',
              GameMode.online => 'Find match',
              _ => 'Connect',
            },
            onTap: _submit,
          ),
        ],
      ),
    );
  }

  List<Widget> _standardFields(Metrics m) {
    return [
      _Label('Game server'),
      SizedBox(height: m.sc(8, 5)),
      TextField(
        controller: _server,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onChanged: (_) => _clearError(),
        onTapOutside: _dismissKeyboard,
        style: AppText.semiBold(m.sc(14, 12), AppColors.textPrimary),
        decoration: fieldDecoration(m, 'ws://host:port'),
      ),
      SizedBox(height: m.sc(16, 10)),
      _Label('Room code'),
      SizedBox(height: m.sc(8, 5)),
      TextField(
        controller: _room,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        onChanged: (_) => _clearError(),
        onTapOutside: _dismissKeyboard,
        style: AppText.bold(
          m.sc(16, 14),
          AppColors.gold,
          letterSpacing: m.sc(2, 1.5),
        ),
        decoration: fieldDecoration(m, 'ABCD'),
      ),
    ];
  }

  // vs Humans is matchmaking over the default server — no manual server
  // field. The debug server override, when armed, still applies via settings.
  List<Widget> _onlineFields(Metrics m) => _roundsSection(m);

  List<Widget> _botsFields(Metrics m) => _roundsSection(m);

  /// The Quickplay/Normal Play choice, shared by every sheet that asks.
  List<Widget> _roundsSection(Metrics m) {
    return [
      _Label('Match length'),
      SizedBox(height: m.sc(8, 5)),
      Row(
        children: [
          Expanded(
            child: RoundsCard(
              title: 'Quickplay',
              subtitle: '3 hands · fast matches',
              selected: _handsPerGame == 3,
              onTap: () => setState(() => _handsPerGame = 3),
            ),
          ),
          SizedBox(width: m.sc(10, 8)),
          Expanded(
            child: RoundsCard(
              title: 'Normal Play',
              subtitle: '5 hands · the full game',
              selected: _handsPerGame == 5,
              onTap: () => setState(() => _handsPerGame = 5),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _privateFields(Metrics m) {
    return [
      Row(
        children: [
          Expanded(
            child: _ModeCard(
              label: 'Create',
              selected: _creating,
              onTap: _enterCreate,
            ),
          ),
          SizedBox(width: m.sc(10, 8)),
          Expanded(
            child: _ModeCard(
              label: 'Join',
              selected: !_creating,
              onTap: _enterJoin,
            ),
          ),
        ],
      ),
      // Create shows the generated room code to share; Join asks for a
      // friend's code instead. The match length is not asked here at all —
      // host and players settle it in the room's lobby before the game deals.
      SizedBox(height: m.sc(18, 10)),
      _Label('Room code'),
      SizedBox(height: m.sc(8, 5)),
      if (_creating) ..._createCodeFields(m) else ..._joinCodeFields(m),
    ];
  }

  List<Widget> _createCodeFields(Metrics m) {
    // A read-only field with the exact same chrome as the Join view's field,
    // so the Create and Join tabs render pixel-identical heights.
    return [
      TextField(
        controller: _room,
        readOnly: true,
        showCursor: false,
        style: AppText.bold(
          m.sc(16, 14),
          AppColors.gold,
          letterSpacing: m.sc(2, 1.5),
        ),
        decoration: fieldDecoration(m, 'Your room code'),
      ),
    ];
  }

  List<Widget> _joinCodeFields(Metrics m) {
    return [
      TextField(
        controller: _room,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        onChanged: (_) => _clearError(),
        onTapOutside: _dismissKeyboard,
        style: AppText.bold(
          m.sc(16, 14),
          AppColors.gold,
          letterSpacing: m.sc(2, 1.5),
        ),
        decoration: fieldDecoration(m, 'ABCD'),
      ),
    ];
  }
}

// -------------------------------------------------------------- small parts

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return Text(
      text,
      textAlign: TextAlign.center,
      style: AppText.semiBold(m.sc(12, 10), AppColors.textMuted),
    );
  }
}

/// A compact settings row: the label on the left with its choice chips
/// grouped on the right — the same minimal arrangement as the in-game quick
/// settings panel.
class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.medium(m.sc(13, 12), AppColors.textOnDark),
          ),
        ),
        SizedBox(width: m.s(12)),
        Wrap(
          spacing: m.s(8),
          runSpacing: m.s(8),
          alignment: WrapAlignment.end,
          children: children,
        ),
      ],
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final TableTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final palette = ThemePalette.of(theme);

    return PressFeedback(
      onTap: onTap,
      child: Container(
        width: m.s(44),
        height: m.s(44),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: palette.felt,
          ),
          border: Border.all(
            color: selected ? AppColors.gold : AppColors.hairline,
            width: selected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }
}

class _CardSwatch extends StatelessWidget {
  const _CardSwatch({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final CardStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final palette = CardFacePalette.of(style);

    return PressFeedback(
      onTap: onTap,
      child: Container(
        width: m.s(36),
        height: m.s(46),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.face,
          borderRadius: BorderRadius.circular(m.s(7)),
          border: Border.all(
            color: selected ? AppColors.gold : AppColors.hairline,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Text('A', style: AppText.bold(m.s(14), palette.red)),
      ),
    );
  }
}

/// A small fanned sample of cards painted in the current card-face style, so
/// switching styles shows the real paint (black ink, red ink, trump border)
/// before leaving settings. [PlayingCardView] reads the current style straight
/// from settings, so the preview updates the moment a swatch is tapped.
class _CardPreview extends StatelessWidget {
  const _CardPreview({required this.cards, required this.width});

  final List<PlayingCard> cards;
  final double width;

  @override
  Widget build(BuildContext context) {
    final mid = (cards.length - 1) / 2;
    final overlap = width * 0.65;
    return SizedBox(
      width: width + (cards.length - 1) * overlap,
      height: width * PlayingCardView.aspect,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < cards.length; i++)
            Transform.translate(
              offset: Offset((i - mid) * overlap, 0),
              child: Transform.rotate(
                angle: (i - mid) * 0.09,
                child: PlayingCardView(card: cards[i], width: width),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPill(
      radius: m.sc(10, 8),
      onTap: onTap,
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(16, 11),
        vertical: m.sc(10, 6),
      ),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: Text(
        label,
        style: AppText.semiBold(
          m.sc(13, 11),
          selected ? AppColors.onGold : AppColors.textOnDark,
        ),
      ),
    );
  }
}

/// A tab pill in the settings sheet's section switcher — like [_ChoiceChip]
/// but stretched to share its row evenly with the other tabs.
class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPill(
      radius: m.sc(10, 8),
      onTap: onTap,
      padding: EdgeInsets.symmetric(vertical: m.sc(10, 6)),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: SizedBox(
        width: double.infinity,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppText.semiBold(
            m.sc(13, 11),
            selected ? AppColors.onGold : AppColors.textOnDark,
          ),
        ),
      ),
    );
  }
}

/// A wide, centered Create/Join choice card used at the top of the Private
/// join sheet — like [_ChoiceChip] but stretched to fill its row and with
/// centered text.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.label,
    required this.selected,
    required this.onTap,
  });

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

/// A wide Quickplay/Normal Play choice card used on the Online join sheet —
/// like [_ModeCard] but with room for a short explanatory subtitle beneath
/// the title.
class RoundsCard extends StatelessWidget {
  const RoundsCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  /// A tighter variant for contexts with less room, like the lobby picker.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPill(
      radius: m.sc(12, 9),
      onTap: onTap,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? m.sc(10, 8) : m.sc(14, 10),
        vertical: compact ? m.sc(9, 6) : m.sc(14, 9),
      ),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.bold(
                compact ? m.sc(13, 11) : m.sc(14, 12),
                selected ? AppColors.onGold : AppColors.textOnDark,
              ),
            ),
            SizedBox(height: compact ? m.sc(2, 1) : m.sc(3, 2)),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.medium(
                compact ? m.sc(10, 9) : m.sc(11, 9.5),
                selected
                    ? AppColors.onGold.withValues(alpha: 0.8)
                    : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: GoldButton(label: label, onTap: onTap),
    );
  }
}
