import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../net/api_client.dart';
import '../../net/api_models.dart';
import '../../state/app_settings.dart';
import '../widgets/backdrop.dart';
import '../widgets/round_history.dart';

/// Profile: what this player has done, and how to keep it.
///
/// Reached from the identity pill in the home screen's top bar. Everything on
/// it comes from the REST surface in `backend/docs/API.md`, which is optional
/// on the server side — a deployment with no database answers `503
/// persistence_disabled`, and that is a supported configuration rather than a
/// fault. Each tab therefore has to render four things, not one: the data, a
/// spinner, an invitation when the player simply has no history yet, and a
/// plain explanation with a retry when the server could not be reached.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.client});

  /// Injected by tests. In the app the screen builds its own from the server
  /// the settings sheet is pointed at, and closes it again on the way out.
  final ApiClient? client;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

enum _ProfileTab { statistics, history, upgrade }

extension on _ProfileTab {
  String get label => switch (this) {
    _ProfileTab.statistics => 'Statistics',
    _ProfileTab.history => 'Game History',
    _ProfileTab.upgrade => 'Upgrade Account',
  };

  /// Landscape and small phones cannot afford three full titles side by side.
  String get shortLabel => switch (this) {
    _ProfileTab.statistics => 'Stats',
    _ProfileTab.history => 'History',
    _ProfileTab.upgrade => 'Account',
  };
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Built in didChangeDependencies rather than initState, for the same reason
  // the settings sheet builds its controllers there: SettingsScope.of() is an
  // InheritedWidget lookup, which Flutter forbids until initState has
  // completed.
  late final ApiClient _client;
  late final bool _ownsClient;
  bool _ready = false;

  _ProfileTab _tab = _ProfileTab.statistics;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _ownsClient = widget.client == null;
    _client = widget.client ?? ApiClient.forSettings(SettingsScope.of(context));
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
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
            glowAlignment: m.isPortrait
                ? const Alignment(-0.85, -0.4)
                : const Alignment(-0.6, -0.2),
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  m.sc(20, 24),
                  m.sc(8, 4),
                  m.sc(20, 24),
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _ProfileHeader(),
                    SizedBox(height: m.sc(14, 8)),
                    _TabSelector(
                      selected: _tab,
                      onSelect: (tab) => setState(() => _tab = tab),
                    ),
                    SizedBox(height: m.sc(14, 8)),
                    Expanded(child: _body()),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _body() => switch (_tab) {
    // Keyed so switching tabs and coming back re-runs the fetch rather than
    // showing a stale page the player has no way to refresh.
    _ProfileTab.statistics => StatisticsTab(
      key: const ValueKey('stats'),
      client: _client,
    ),
    _ProfileTab.history => HistoryTab(
      key: const ValueKey('history'),
      client: _client,
    ),
    _ProfileTab.upgrade => UpgradeTab(
      key: const ValueKey('upgrade'),
      client: _client,
      // A restore swaps the account underneath the header; repaint it with
      // the restored profile from the identity store.
      onRestored: () => setState(() {}),
    ),
  };
}

// ---------------------------------------------------------------- chrome

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final settings = SettingsScope.of(context);
    final user = settings.identity.cachedUser;
    final name = user?.displayName.isNotEmpty == true
        ? user!.displayName
        : settings.playerName;

    return Row(
      children: [
        GlassPill(
          radius: m.sc(20, 18),
          padding: EdgeInsets.all(m.sc(8, 9)),
          border: AppColors.hairlineStrong,
          onTap: () => Navigator.of(context).maybePop(),
          child: Icon(
            Icons.arrow_back_rounded,
            size: m.sc(16, 19),
            color: AppColors.textOnDark,
          ),
        ),
        SizedBox(width: m.sc(12, 10)),
        Container(
          width: m.sc(40, 32),
          height: m.sc(40, 32),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [AppColors.gold, AppColors.goldDeep],
            ),
            border: Border.all(
              color: AppColors.goldBorder.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
            style: AppText.bold(m.sc(17, 14), AppColors.onGold),
          ),
        ),
        SizedBox(width: m.sc(10, 8)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bold(m.sc(17, 14), AppColors.textPrimary),
              ),
              SizedBox(height: m.s(2)),
              Text(
                user == null
                    ? 'Guest account'
                    : (user.isLinked ? 'Signed in' : 'Guest account'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.medium(m.sc(11, 10), AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabSelector extends StatelessWidget {
  const _TabSelector({required this.selected, required this.onSelect});

  final _ProfileTab selected;
  final ValueChanged<_ProfileTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      children: [
        for (final tab in _ProfileTab.values) ...[
          Expanded(
            child: _TabPill(
              // The full title is what the brief names the tab; the short one
              // only appears where three full titles would not fit, which on a
              // 390pt-wide phone is every one of them.
              label: m.isPortrait ? tab.shortLabel : tab.label,
              selected: tab == selected,
              onTap: () => onSelect(tab),
            ),
          ),
          if (tab != _ProfileTab.values.last) SizedBox(width: m.sc(8, 10)),
        ],
      ],
    );
  }
}

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
      radius: m.sc(12, 12),
      onTap: onTap,
      padding: EdgeInsets.symmetric(
        vertical: m.sc(11, 11),
        horizontal: m.sc(8, 10),
      ),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: SizedBox(
        width: double.infinity,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.semiBold(
            m.sc(12, 13),
            selected ? AppColors.onGold : AppColors.textOnDark,
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- states

/// The spinner every tab shows while its first request is in flight.
class ProfileLoading extends StatelessWidget {
  const ProfileLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Center(
      child: SizedBox(
        width: m.s(28),
        height: m.s(28),
        child: const CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation(AppColors.gold),
        ),
      ),
    );
  }
}

/// The one surface behind "nothing here yet", "history is off on this server"
/// and "that did not load". They differ in wording and in whether there is
/// something to retry, not in shape — and a failure the player can act on
/// should not look more alarming than one they cannot.
class ProfileMessage extends StatelessWidget {
  const ProfileMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: m.sc(24, 12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: m.sc(56, 44),
              height: m.sc(56, 44),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.panel,
                border: Border.all(color: AppColors.hairlineStrong),
              ),
              child: Icon(icon, size: m.sc(24, 20), color: AppColors.textMuted),
            ),
            SizedBox(height: m.sc(14, 10)),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.bold(m.sc(15, 13), AppColors.textPrimary),
            ),
            SizedBox(height: m.sc(6, 4)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.s(300)),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: AppText.medium(m.sc(12, 11), AppColors.textMuted),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              SizedBox(height: m.sc(16, 12)),
              GlassPill(
                radius: m.sc(12, 12),
                onTap: onAction,
                padding: EdgeInsets.symmetric(
                  horizontal: m.sc(20, 16),
                  vertical: m.sc(10, 10),
                ),
                background: AppColors.gold,
                border: AppColors.gold,
                child: Text(
                  actionLabel!,
                  style: AppText.bold(m.sc(13, 13), AppColors.onGold),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Turns a failure into the right kind of message.
///
/// `persistence_disabled` is the one that matters: the server is healthy and
/// the player did nothing wrong, it simply has no database, so it gets an
/// explanation and no retry button — there is nothing a retry would change.
ProfileMessage messageForError(Object error, {VoidCallback? onRetry}) {
  if (error is ApiException) {
    if (error.isPersistenceDisabled) {
      return const ProfileMessage(
        icon: Icons.cloud_off_rounded,
        title: 'History is off on this server',
        body:
            'This server is running without a database, so games and '
            'statistics are not being recorded. Play is unaffected.',
      );
    }
    if (error.isNotImplemented) {
      return ProfileMessage(
        icon: Icons.schedule_rounded,
        title: 'Not available yet',
        body: error.displayMessage,
      );
    }
    return ProfileMessage(
      icon: Icons.wifi_off_rounded,
      title: 'Could not load',
      body: error.displayMessage,
      actionLabel: onRetry == null ? null : 'Try again',
      onAction: onRetry,
    );
  }
  return ProfileMessage(
    icon: Icons.error_outline_rounded,
    title: 'Could not load',
    body: 'Something unexpected happened. Please try again.',
    actionLabel: onRetry == null ? null : 'Try again',
    onAction: onRetry,
  );
}

/// A titled band of tiles, the way the settings sheet titles its groups.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.semiBold(m.sc(12, 10), AppColors.textMuted)),
        SizedBox(height: m.sc(8, 6)),
        // IntrinsicHeight, not CrossAxisAlignment.stretch: this row lives in a
        // ListView, where the incoming height is unbounded and "stretch" would
        // ask a tile to be infinitely tall. Measuring the tallest tile and
        // matching the others to it is what keeps a row of tiles square-edged.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                Expanded(child: children[i]),
                if (i != children.length - 1) SizedBox(width: m.sc(8, 8)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- statistics tab

/// The scope selector over the §3.2 counters.
///
/// `GET /v1/me/stats` returns all five scopes in one response, so switching
/// scope is a local rebuild rather than a request — which is what lets the
/// selector feel instant and is the reason the endpoint is shaped that way.
class StatisticsTab extends StatefulWidget {
  const StatisticsTab({super.key, required this.client});

  final ApiClient client;

  @override
  State<StatisticsTab> createState() => _StatisticsTabState();
}

class _StatisticsTabState extends State<StatisticsTab> {
  StatsScope _scope = StatsScope.all;
  StatsBundle? _stats;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stats = await widget.client.fetchStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const ProfileLoading();
    final error = _error;
    if (error != null) return messageForError(error, onRetry: _load);

    final m = Metrics.of(context);
    final stats = (_stats ?? const StatsBundle([])).of(_scope);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScopeSelector(
          selected: _scope,
          onSelect: (scope) => setState(() => _scope = scope),
        ),
        SizedBox(height: m.sc(14, 10)),
        Expanded(
          child: stats.hasPlayed
              ? _StatsBody(stats: stats)
              : ProfileMessage(
                  icon: Icons.sports_esports_outlined,
                  title: _scope == StatsScope.all
                      ? 'No games yet'
                      : 'Nothing in ${stats.scope.label} yet',
                  body: _scope == StatsScope.all
                      ? 'Play a hand and this fills up — every mode is counted, '
                            'including games against bots.'
                      : 'Play a ${stats.scope.label} game and its own records '
                            'start here, separately from every other mode.',
                ),
        ),
      ],
    );
  }
}

class _ScopeSelector extends StatelessWidget {
  const _ScopeSelector({required this.selected, required this.onSelect});

  final StatsScope selected;
  final ValueChanged<StatsScope> onSelect;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    // Horizontally scrollable rather than five Expanded pills: "Quickplay" and
    // "vs Bots" would both ellipsize into nonsense at a fifth of a 390pt width.
    return SizedBox(
      height: m.sc(34, 30),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final scope in StatsScope.values) ...[
            _ScopeChip(
              label: scope.label,
              selected: scope == selected,
              onTap: () => onSelect(scope),
            ),
            if (scope != StatsScope.values.last) SizedBox(width: m.sc(8, 8)),
          ],
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
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
      radius: m.sc(10, 11),
      onTap: onTap,
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(14, 12),
        vertical: m.sc(8, 8),
      ),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: Center(
        child: Text(
          label,
          style: AppText.semiBold(
            m.sc(12, 12),
            selected ? AppColors.onGold : AppColors.textOnDark,
          ),
        ),
      ),
    );
  }
}

/// The figures themselves.
///
/// Deliberately not a flat grid of twelve equal numbers: win rate and games
/// played carry the headline, everything else is a supporting tile. Twelve
/// tiles at one weight reads as a spreadsheet, and a profile should read as a
/// record of a person.
class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.stats});

  final ScopeStats stats;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return ListView(
      padding: EdgeInsets.only(bottom: m.sc(16, 10)),
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _HeroStat(
                  value: '${(stats.winRate * 100).round()}%',
                  label: 'Win rate',
                  support: '${stats.gamesWon}W · ${stats.gamesLost}L',
                ),
              ),
              SizedBox(width: m.sc(10, 10)),
              Expanded(
                child: _HeroStat(
                  value: '${stats.gamesPlayed}',
                  label: 'Games played',
                  support: '${stats.gamesCompleted} finished',
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: m.sc(16, 12)),
        _Section(
          title: 'Results',
          children: [
            _StatTile(value: placeLabel(stats.bestPlace), label: 'Best finish'),
            _StatTile(value: '${stats.currentWinStreak}', label: 'Streak'),
            _StatTile(value: '${stats.bestWinStreak}', label: 'Best streak'),
          ],
        ),
        SizedBox(height: m.sc(14, 10)),
        _Section(
          title: 'Scores',
          children: [
            _StatTile(
              value: stats.averageScore.toStringAsFixed(1),
              label: 'Average',
            ),
            _StatTile(
              value: stats.highestGameScore.toStringAsFixed(1),
              label: 'Best game',
            ),
            _StatTile(
              value: stats.highestHandScore.toStringAsFixed(1),
              label: 'Best hand',
            ),
          ],
        ),
        SizedBox(height: m.sc(14, 10)),
        _Section(
          title: 'Bidding',
          children: [
            _StatTile(
              value: '${(stats.bidAccuracy * 100).round()}%',
              label: 'Bids made',
            ),
            _StatTile(value: '${stats.highestBid}', label: 'Highest bid'),
            _StatTile(value: '${stats.handsPlayed}', label: 'Hands'),
          ],
        ),
        // The only nullable field in the whole stats object, and the row is
        // simply absent when it is null rather than showing a placeholder
        // date. A scope with games in it always has one.
        if (stats.lastPlayedAt case final lastPlayed?) ...[
          SizedBox(height: m.sc(14, 10)),
          Text(
            'Last played ${formatPlayedAt(lastPlayed).toLowerCase()}',
            style: AppText.medium(m.sc(11, 10), AppColors.textFaint),
          ),
        ],
      ],
    );
  }
}

/// 1–4 as a placing, or an em dash for a scope nobody has been ranked in.
String placeLabel(int place) => switch (place) {
  1 => '1st',
  2 => '2nd',
  3 => '3rd',
  4 => '4th',
  _ => '—',
};

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.value,
    required this.label,
    required this.support,
  });

  final String value;
  final String label;
  final String support;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(16, 14),
        vertical: m.sc(16, 11),
      ),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(m.sc(14, 11)),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppText.bold(m.sc(30, 24), AppColors.gold),
            ),
          ),
          SizedBox(height: m.s(2)),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.semiBold(m.sc(12, 11), AppColors.textPrimary),
          ),
          SizedBox(height: m.s(2)),
          Text(
            support,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.medium(m.sc(11, 10), AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(10, 10),
        vertical: m.sc(10, 8),
      ),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(m.sc(11, 9)),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppText.bold(m.sc(17, 15), AppColors.textPrimary),
            ),
          ),
          SizedBox(height: m.s(2)),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.medium(m.sc(11, 10), AppColors.textFaint),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- history tab

/// Reverse-chronological history, paged with the keyset cursor from
/// `GET /v1/me/games`.
///
/// The cursor is why this appends rather than re-requesting a page number: a
/// game finishing while the player scrolls shifts every offset, and an offset
/// pager would quietly skip a row. Appending on `nextCursor` cannot.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, required this.client});

  final ApiClient client;

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  static const _pageSize = 20;

  final List<GameSummary> _games = [];
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.client.fetchGames(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _games
          ..clear()
          ..addAll(page.games);
        _cursor = page.nextCursor;
        _exhausted = !page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || _cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.fetchGames(
        limit: _pageSize,
        cursor: _cursor,
      );
      if (!mounted) return;
      setState(() {
        _games.addAll(page.games);
        _cursor = page.nextCursor;
        _exhausted = !page.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // A page that fails to append is not worth replacing the list the player
      // is already reading; stop paging and let pull-to-refresh recover.
      setState(() {
        _loadingMore = false;
        _exhausted = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const ProfileLoading();
    final error = _error;
    if (error != null) return messageForError(error, onRetry: _load);

    final m = Metrics.of(context);

    if (_games.isEmpty) {
      // Still refreshable: an empty history on a server that has games is
      // indistinguishable from one that genuinely has none, so the pull
      // gesture has to keep working here too.
      return RefreshIndicator(
        onRefresh: _load,
        color: AppColors.gold,
        backgroundColor: AppColors.panelSoft,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: m.sc(320, 180),
              child: const ProfileMessage(
                icon: Icons.history_rounded,
                title: 'No games yet',
                body:
                    'Finished games land here — quickplay, private rooms, LAN '
                    'and games against bots alike.',
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.gold,
      backgroundColor: AppColors.panelSoft,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < m.s(400)) _loadMore();
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(bottom: m.sc(16, 10)),
          itemCount: _games.length + (_exhausted ? 0 : 1),
          separatorBuilder: (_, _) => SizedBox(height: m.sc(10, 8)),
          itemBuilder: (context, index) {
            if (index >= _games.length) {
              return Padding(
                padding: EdgeInsets.symmetric(vertical: m.s(16)),
                child: const ProfileLoading(),
              );
            }
            final game = _games[index];
            return GameHistoryRow(
              game: game,
              onTap: () =>
                  showGameDetail(context, client: widget.client, game: game),
            );
          },
        ),
      ),
    );
  }
}

/// One game in the history list.
class GameHistoryRow extends StatelessWidget {
  const GameHistoryRow({super.key, required this.game, this.onTap});

  final GameSummary game;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final you = game.you;
    final won = you?.isWinner ?? false;
    final opponents = game.opponents;

    return PressFeedback(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.sc(14, 12),
          vertical: m.sc(12, 9),
        ),
        decoration: BoxDecoration(
          color: won
              ? AppColors.gold.withValues(alpha: 0.08)
              : AppColors.panelSoft,
          borderRadius: BorderRadius.circular(m.sc(14, 11)),
          border: Border.all(
            color: won
                ? AppColors.goldBorder.withValues(alpha: 0.5)
                : AppColors.hairline,
          ),
        ),
        child: Row(
          children: [
            _PlaceBadge(place: you?.place ?? 0),
            SizedBox(width: m.sc(12, 10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _ModeChip(label: game.modeLabel),
                      SizedBox(width: m.sc(8, 6)),
                      Flexible(
                        child: Text(
                          formatPlayedAt(game.playedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.medium(
                            m.sc(11, 10),
                            AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (!game.completed) ...[
                        SizedBox(width: m.sc(6, 5)),
                        Text(
                          '· unfinished',
                          maxLines: 1,
                          style: AppText.medium(
                            m.sc(11, 10),
                            AppColors.textFaint,
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: m.s(4)),
                  Text(
                    opponents.isEmpty
                        ? 'Solo table'
                        : opponents.map((p) => p.displayName).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.medium(m.sc(12, 11), AppColors.textSubtle),
                  ),
                ],
              ),
            ),
            SizedBox(width: m.sc(10, 8)),
            Text(
              (you?.finalScore ?? 0).toStringAsFixed(1),
              style: AppText.bold(
                m.sc(16, 14),
                won ? AppColors.gold : AppColors.textPrimary,
              ),
            ),
            SizedBox(width: m.sc(4, 3)),
            Icon(
              Icons.chevron_right_rounded,
              size: m.sc(20, 18),
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// The placing, with first place set apart — a win is the thing the player is
/// scanning the list for, so it gets the gold and everything else does not.
class _PlaceBadge extends StatelessWidget {
  const _PlaceBadge({required this.place});

  final int place;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final won = place == 1;

    return Container(
      width: m.sc(38, 32),
      height: m.sc(38, 32),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(m.sc(10, 8)),
        gradient: won
            ? const LinearGradient(colors: [AppColors.gold, AppColors.goldDeep])
            : null,
        color: won ? null : AppColors.panel,
        border: Border.all(
          color: won ? AppColors.goldBorder : AppColors.hairlineStrong,
        ),
      ),
      child: Text(
        placeLabel(place),
        style: AppText.bold(
          m.sc(13, 11),
          won ? AppColors.onGold : AppColors.textOnDark,
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(8, 7),
        vertical: m.sc(3, 2),
      ),
      decoration: BoxDecoration(
        color: AppColors.hairline,
        borderRadius: BorderRadius.circular(m.sc(7, 6)),
      ),
      child: Text(
        label,
        style: AppText.semiBold(m.sc(10, 9), AppColors.textSubtle),
      ),
    );
  }
}

/// Day-level stamp on the device's own clock. Recent games are named rather
/// than dated, because "yesterday" is how a player thinks about the game they
/// are looking for.
String formatPlayedAt(DateTime? when, {DateTime? now}) {
  if (when == null) return 'Unknown date';
  final local = when.toLocal();
  final today = DateTime(
    (now ?? DateTime.now()).year,
    (now ?? DateTime.now()).month,
    (now ?? DateTime.now()).day,
  );
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final time =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  if (difference == 0) return 'Today $time';
  if (difference == 1) return 'Yesterday $time';
  if (difference > 1 && difference < 7) return '$difference days ago';
  if (day.year == today.year) return '${local.day} ${months[local.month - 1]}';
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

// --------------------------------------------------------- game scorecard

/// Opens the hand-by-hand scoreboard for one game.
Future<void> showGameDetail(
  BuildContext context, {
  required ApiClient client,
  required GameSummary game,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (context) => GameDetailDialog(client: client, game: game),
  );
}

/// The same card chrome and the same score table as [RoundHistoryOverlay], fed
/// from `GET /v1/games/{id}` instead of from a live [GameView] — deliberately
/// the same shape, because a scorecard the player already knows how to read is
/// worth more than a third layout for the same numbers.
class GameDetailDialog extends StatefulWidget {
  const GameDetailDialog({super.key, required this.client, required this.game});

  final ApiClient client;
  final GameSummary game;

  @override
  State<GameDetailDialog> createState() => _GameDetailDialogState();
}

class _GameDetailDialogState extends State<GameDetailDialog> {
  GameDetail? _detail;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.client.fetchGame(widget.game.id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: m.s(420),
          maxHeight:
              MediaQuery.sizeOf(context).height * (m.isPortrait ? 0.7 : 0.9),
        ),
        child: Padding(
          padding: EdgeInsets.all(m.sc(20, 12)),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              m.sc(20, 14),
              m.sc(18, 12),
              m.sc(20, 14),
              m.sc(18, 12),
            ),
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.game.modeLabel,
                            style: AppText.bold(
                              m.sc(17, 14),
                              AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            formatPlayedAt(widget.game.playedAt),
                            style: AppText.medium(
                              m.sc(11, 10),
                              AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PressFeedback(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: Padding(
                        padding: EdgeInsets.all(m.s(4)),
                        child: Text(
                          '✕',
                          style: AppText.semiBold(m.s(15), AppColors.textMuted),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: m.sc(10, 8)),
                Flexible(child: _content(m)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(Metrics m) {
    if (_loading) {
      return SizedBox(height: m.sc(160, 100), child: const ProfileLoading());
    }
    final error = _error;
    if (error != null) {
      return SizedBox(
        height: m.sc(200, 130),
        child: messageForError(error, onRetry: _load),
      );
    }
    final detail = _detail!;
    if (detail.hands.isEmpty) {
      return SizedBox(
        height: m.sc(160, 110),
        child: const ProfileMessage(
          icon: Icons.receipt_long_outlined,
          title: 'No scorecard',
          body: 'This game was recorded without its hand-by-hand detail.',
        ),
      );
    }
    return GameScorecard(detail: detail);
  }
}

/// `Rnd | seat | seat | seat | seat` — the column layout of
/// `ui/widgets/round_history.dart`, over a completed game's hands.
class GameScorecard extends StatelessWidget {
  const GameScorecard({super.key, required this.detail});

  final GameDetail detail;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final players = [...detail.game.players]
      ..sort((a, b) => a.seat.compareTo(b.seat));
    final seats = [for (final player in players) player.seat];
    final indices = detail.handIndices;
    final youSeat = detail.game.you?.seat;
    final youIndex = youSeat == null ? -1 : seats.indexOf(youSeat) + 1;

    // A soft gold band standing behind the local player's whole column, so
    // their scores read at a glance even when two players share a name.
    return YouColumnHighlight(
      youIndex: youIndex,
      color: AppColors.gold.withValues(alpha: 0.08),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScoreRow(
            cells: [
              'Rnd',
              for (final player in players)
                player.displayName.isEmpty
                    ? 'Seat ${player.seat}'
                    : player.displayName,
            ],
            styleFor: (index) => AppText.semiBold(
              m.sc(11, 10),
              index > 0 && seats[index - 1] == youSeat
                  ? AppColors.gold
                  : AppColors.textFaint,
            ),
          ),
          SizedBox(height: m.s(6)),
          Container(height: 1, color: AppColors.hairline),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final handIndex in indices) ...[
                    SizedBox(height: m.s(8)),
                    _ScoreRow(
                      cells: [
                        '${handIndex + 1}',
                        for (final seat in seats)
                          detail
                                  .cell(handIndex, seat)
                                  ?.scoreDelta
                                  .toStringAsFixed(1) ??
                              '–',
                      ],
                      styleFor: (index) => index == 0
                          ? AppText.medium(m.sc(12, 11), AppColors.textMuted)
                          : AppText.semiBold(
                              m.sc(12, 11),
                              _deltaColor(
                                detail
                                    .cell(handIndex, seats[index - 1])
                                    ?.scoreDelta,
                              ),
                            ),
                    ),
                    SizedBox(height: m.s(2)),
                    _ScoreRow(
                      cells: [
                        '',
                        for (final seat in seats)
                          switch (detail.cell(handIndex, seat)) {
                            final hand? =>
                              '${hand.bid} bid · ${hand.tricksWon} won',
                            _ => '',
                          },
                      ],
                      styleFor: (_) =>
                          AppText.medium(m.sc(9, 8), AppColors.textFaint),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: m.s(8)),
          Container(height: 1, color: AppColors.hairline),
          SizedBox(height: m.s(8)),
          _ScoreRow(
            cells: [
              'Total',
              for (final player in players)
                player.finalScore.toStringAsFixed(1),
            ],
            styleFor: (index) => index == 0
                ? AppText.bold(m.sc(12, 11), AppColors.textPrimary)
                : AppText.bold(m.sc(13, 12), AppColors.gold),
          ),
        ],
      ),
    );
  }

  static Color _deltaColor(double? delta) {
    if (delta == null) return AppColors.textFaint;
    if (delta < 0) return AppColors.danger;
    if (delta > 0) return AppColors.gold;
    return AppColors.textMuted;
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.cells, required this.styleFor});

  /// First entry is the leading (round/label) column; the rest are one per
  /// seat.
  final List<String> cells;
  final TextStyle Function(int index) styleFor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: i == 0 ? 2 : 3,
            child: Text(
              cells[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: i == 0 ? TextAlign.left : TextAlign.center,
              style: styleFor(i),
            ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------- upgrade tab

/// The account tab: who you are now, and what linking a login would buy.
///
/// The buttons are real and wired to [ApiClient.linkAccount]; they are held
/// shut by [kAccountLinkingEnabled], which is false because the endpoint
/// answers `501` and there is no Firebase SDK in this app. Building the flow
/// now and gating it means switching it on later is a constant and a sign-in
/// SDK, not a new screen.
class UpgradeTab extends StatefulWidget {
  const UpgradeTab({super.key, required this.client, this.onRestored});

  final ApiClient client;

  /// Fired after a successful restore, so the header above the tabs (which
  /// reads the identity store, not this tab's state) can repaint with the
  /// restored account's name.
  final VoidCallback? onRestored;

  @override
  State<UpgradeTab> createState() => _UpgradeTabState();
}

class _UpgradeTabState extends State<UpgradeTab> {
  UserProfile? _user;
  Object? _error;
  bool _loading = true;
  bool _restoring = false;
  bool _resolving = false;

  /// The abandoned guest this install left behind on its last restore, if the
  /// player has not decided what to do with its games yet. Survives restarts
  /// through the identity store, so the offer reappears here rather than
  /// being lost because the app was killed before the decision.
  AbandonedAccount? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = await widget.client.fetchMe();
      if (!mounted) return;
      setState(() {
        _user = user;
        _pending = widget.client.identity.pendingAbandoned;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // A cached profile is better than nothing: the identity section can
        // still say who this player is while the server is unreachable.
        _user = widget.client.identity.cachedUser;
        _pending = widget.client.identity.pendingAbandoned;
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _link(AuthProvider provider) async {
    if (!kAccountLinkingEnabled) return;
    // The id token comes from a sign-in SDK this build does not ship. When one
    // lands, signing in with [provider] and handing the resulting Firebase id
    // token to linkAccount is the only thing that has to be filled in here —
    // the endpoint, the refresh and the error path are already right.
    try {
      await widget.client.linkAccount('');
      if (!mounted) return;
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.isNotImplemented
                ? '${provider.label} sign-in is coming soon.'
                : error.displayMessage,
          ),
        ),
      );
    }
  }

  /// Opens the restore dialog and, on a confirmed id, hands this device over
  /// to the account it names. The server re-anchors this install's device id
  /// to that account and returns a session for it; the identity store already
  /// has the new user, so the header can repaint right away. When the replaced
  /// install still had games, the offer to bring them along or leave them
  /// behind is made immediately — and, if the player puts it off, survives in
  /// the identity store until this tab is opened again.
  Future<void> _restore() async {
    final accountId = await showDialog<String>(
      context: context,
      builder: (context) => const _RestoreDialog(),
    );
    if (accountId == null || !mounted) return;

    setState(() => _restoring = true);
    try {
      final result = await widget.client.restoreAccount(accountId);
      if (!mounted) return;
      widget.onRestored?.call();
      setState(() {
        _restoring = false;
        _pending = result.abandoned;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Welcome back, ${result.session.user.displayName.isNotEmpty ? result.session.user.displayName : 'player'}. '
            'Your history is restored on this device.',
          ),
        ),
      );
      await widget.client.identity.savePendingAbandoned(result.abandoned);
      await _load();
      if (!mounted) return;
      if (result.abandoned != null) await _resolveAbandoned(result.abandoned!);
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.displayMessage)));
      setState(() => _restoring = false);
    }
  }

  /// Offers the merge-or-discard decision for [abandoned], the guest account
  /// this install used to be. The dialog asks up front; choosing "Later"
  /// (or killing the app) keeps the offer on the identity store and in [_pending]
  /// so the card at the top of this tab can make it again.
  Future<void> _resolveAbandoned(AbandonedAccount abandoned) async {
    final choice = await showDialog<_AbandonedChoice>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AbandonedDialog(abandoned: abandoned),
    );
    if (choice == null || !mounted) return;
    await _decideAbandoned(abandoned, choice);
  }

  /// The decisions themselves — [choice] is what the discarded-install's games
  /// should do. Also the card's direct path, which already knows the choice.
  Future<void> _decideAbandoned(
    AbandonedAccount abandoned,
    _AbandonedChoice choice,
  ) async {
    setState(() => _resolving = true);
    try {
      switch (choice) {
        case _AbandonedChoice.merge:
          await widget.client.mergeAbandoned(abandoned.accountId);
        case _AbandonedChoice.discard:
          await widget.client.discardAbandoned(abandoned.accountId);
      }
      if (!mounted) return;
      setState(() => _pending = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            choice == _AbandonedChoice.merge
                ? 'Your ${abandoned.games} game${abandoned.games == 1 ? '' : 's'} '
                      'joined your history.'
                : 'Those games were left behind. The restored account keeps its own history.',
          ),
        ),
      );
      await widget.client.identity.savePendingAbandoned(null);
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.displayMessage)));
    }
    setState(() => _resolving = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const ProfileLoading();

    final m = Metrics.of(context);
    final user = _user;
    final error = _error;

    // Only a hard failure with nothing cached takes over the tab. Otherwise
    // the promise copy and the disabled buttons are still worth showing —
    // none of it depends on the network.
    if (user == null && error != null) {
      return messageForError(error, onRetry: _load);
    }

    return ListView(
      padding: EdgeInsets.only(bottom: m.sc(16, 10)),
      children: [
        _IdentityCard(user: user),
        // A restore left this install's old guest behind, still carrying
        // games. Offer to bring them along or leave them — the offer survives
        // a restart, so this card is what makes the decision later possible.
        if (_pending != null) ...[
          SizedBox(height: m.sc(16, 12)),
          _AbandonedCard(
            pending: _pending!,
            busy: _resolving,
            onMerge: () => _decideAbandoned(_pending!, _AbandonedChoice.merge),
            onDiscard: () =>
                _decideAbandoned(_pending!, _AbandonedChoice.discard),
          ),
        ],
        // Restoring only makes sense from a bare guest install; a signed-in
        // account would be refused by the server, so it is not offered.
        if (user?.isGuest ?? false) ...[
          SizedBox(height: m.sc(16, 12)),
          _RestoreCard(busy: _restoring, onTap: _restore),
        ],
        SizedBox(height: m.sc(16, 12)),
        Text(
          'Link a sign-in',
          style: AppText.semiBold(m.sc(12, 10), AppColors.textMuted),
        ),
        SizedBox(height: m.sc(8, 6)),
        for (final provider in const [
          AuthProvider.google,
          AuthProvider.facebook,
          AuthProvider.apple,
        ]) ...[
          _ProviderButton(
            provider: provider,
            linked:
                user?.identities.any((i) => i.provider == provider) ?? false,
            onTap: kAccountLinkingEnabled ? () => _link(provider) : null,
          ),
          SizedBox(height: m.sc(8, 6)),
        ],
        SizedBox(height: m.sc(8, 6)),
        const _UpgradePromise(
          icon: Icons.inventory_2_outlined,
          title: 'Nothing is lost',
          body:
              'Linking adds a way to sign in to the account you already have. '
              'Every game, every statistic and every record stays exactly where '
              'it is — this account keeps its id.',
        ),
        SizedBox(height: m.sc(10, 8)),
        const _UpgradePromise(
          icon: Icons.devices_rounded,
          title: 'The same account on any device',
          body:
              'Sign in with the same Google account on an iPhone and you land '
              'on this account, with all of its history. It is the sign-in '
              'method that carries it, not the phone — so link more than one '
              'and any of them will get you back in.',
        ),
        SizedBox(height: m.sc(12, 10)),
        Text(
          'Today this account lives on this device only. Reinstalling the app '
          'or switching phones would start a new one.',
          style: AppText.medium(m.sc(11, 10), AppColors.textFaint),
        ),
      ],
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.user});

  final UserProfile? user;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final linked = user?.portableIdentities ?? const <UserIdentity>[];

    return Container(
      padding: EdgeInsets.all(m.sc(16, 12)),
      decoration: BoxDecoration(
        color: AppColors.panelSoft,
        borderRadius: BorderRadius.circular(m.sc(14, 11)),
        border: Border.all(color: AppColors.hairlineStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                linked.isEmpty
                    ? Icons.person_outline_rounded
                    : Icons.verified_rounded,
                size: m.sc(18, 16),
                color: linked.isEmpty ? AppColors.textMuted : AppColors.success,
              ),
              SizedBox(width: m.sc(8, 6)),
              Expanded(
                child: Text(
                  linked.isEmpty ? 'Guest account' : 'Signed in',
                  style: AppText.bold(m.sc(14, 12), AppColors.textPrimary),
                ),
              ),
            ],
          ),
          SizedBox(height: m.sc(6, 4)),
          Text(
            linked.isEmpty
                ? 'You are a real account already — every game you play is '
                      'recorded against it. It just has no way to sign in from '
                      'another device yet.'
                : 'Signed in with ${linked.map((i) => i.provider.label).join(', ')}.',
            style: AppText.medium(m.sc(12, 11), AppColors.textMuted),
          ),
          SizedBox(height: m.sc(14, 10)),
          Row(
            children: [
              Icon(
                Icons.tag_rounded,
                size: m.sc(16, 14),
                color: AppColors.textMuted,
              ),
              SizedBox(width: m.sc(8, 6)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Account id',
                      style: AppText.semiBold(
                        m.sc(11, 10),
                        AppColors.textMuted,
                      ),
                    ),
                    SizedBox(height: m.s(2)),
                    Text(
                      user?.id ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.medium(
                        m.sc(12, 11),
                        AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: user?.id == null ? null : () => _copyId(context),
                tooltip: 'Copy account id',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.copy_rounded,
                  size: m.sc(16, 14),
                  color: AppColors.gold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copyId(BuildContext context) async {
    final id = user?.id;
    if (id == null || id.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account id copied to the clipboard.')),
    );
  }
}

/// The "bring my saved account to this phone" path: what the fresh install's
/// owner types an account id into, and what walks them through it.
enum _AbandonedChoice { merge, discard }

/// The persistent offer for a restore that left the replaced install's games
/// behind. Shown whenever a decision is still owed; two tappable decisions,
/// and the copy spells out what each one does to those games.
class _AbandonedCard extends StatelessWidget {
  const _AbandonedCard({
    required this.pending,
    required this.busy,
    required this.onMerge,
    required this.onDiscard,
  });

  final AbandonedAccount pending;
  final bool busy;
  final VoidCallback onMerge;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final games = pending.games;

    return Container(
      padding: EdgeInsets.all(m.sc(16, 12)),
      decoration: BoxDecoration(
        color: AppColors.panelSoft,
        borderRadius: BorderRadius.circular(m.sc(14, 11)),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.devices_other_rounded,
                size: m.sc(18, 16),
                color: AppColors.gold,
              ),
              SizedBox(width: m.sc(8, 6)),
              Expanded(
                child: Text(
                  'Games from your old install',
                  style: AppText.bold(m.sc(14, 12), AppColors.textPrimary),
                ),
              ),
            ],
          ),
          SizedBox(height: m.sc(6, 4)),
          Text(
            'Restoring this device left your previous account behind with '
            '$games game${games == 1 ? '' : 's'} on it. Bring them into your '
            'restored history, or leave them behind for good.',
            style: AppText.medium(m.sc(12, 11), AppColors.textMuted),
          ),
          SizedBox(height: m.sc(12, 10)),
          Row(
            children: [
              Expanded(
                child: GlassPill(
                  radius: m.sc(12, 12),
                  onTap: busy ? null : onMerge,
                  padding: EdgeInsets.symmetric(vertical: m.sc(13, 11)),
                  background: AppColors.gold,
                  border: AppColors.gold,
                  child: busy
                      ? _Spinner(width: m.sc(18, 16), height: m.sc(18, 16))
                      : Text(
                          'Bring them along',
                          textAlign: TextAlign.center,
                          style: AppText.semiBold(
                            m.sc(12, 12),
                            AppColors.onGold,
                          ),
                        ),
                ),
              ),
              SizedBox(width: m.sc(10, 8)),
              Expanded(
                child: GlassPill(
                  radius: m.sc(12, 12),
                  onTap: busy ? null : onDiscard,
                  padding: EdgeInsets.symmetric(vertical: m.sc(13, 11)),
                  background: AppColors.panel,
                  border: AppColors.hairlineStrong,
                  child: busy
                      ? _Spinner(width: m.sc(18, 16), height: m.sc(18, 16))
                      : Text(
                          'Leave them behind',
                          textAlign: TextAlign.center,
                          style: AppText.semiBold(
                            m.sc(12, 12),
                            AppColors.textOnDark,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The immediate merge-or-discard question asked right after a restore that
/// left games behind. Returns the choice, or null for "Later" — the offer
/// stays in the identity store either way.
class _AbandonedDialog extends StatelessWidget {
  const _AbandonedDialog({required this.abandoned});

  final AbandonedAccount abandoned;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final games = abandoned.games;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: m.s(28)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.s(340)),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Games from your old device',
                style: AppText.bold(m.s(16), AppColors.textPrimary),
              ),
              SizedBox(height: m.s(6)),
              Text(
                'Your previous account still has $games game${games == 1 ? '' : 's'} '
                'on it. Bring them into this restored account, or leave them '
                'behind for good?',
                style: AppText.medium(m.s(13), AppColors.textMuted),
              ),
              SizedBox(height: m.s(18)),
              _DialogAction(
                label: 'Bring them along',
                background: AppColors.gold,
                border: AppColors.gold,
                foreground: AppColors.onGold,
                onTap: () => Navigator.of(context).pop(_AbandonedChoice.merge),
              ),
              SizedBox(height: m.s(10)),
              _DialogAction(
                label: 'Leave them behind',
                background: AppColors.panel,
                border: AppColors.hairlineStrong,
                foreground: AppColors.textOnDark,
                onTap: () =>
                    Navigator.of(context).pop(_AbandonedChoice.discard),
              ),
              SizedBox(height: m.s(10)),
              Align(
                alignment: Alignment.center,
                child: PressFeedback(
                  onTap: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: EdgeInsets.all(m.s(4)),
                    child: Text(
                      'Decide later',
                      style: AppText.semiBold(m.s(12), AppColors.textFaint),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogAction extends StatelessWidget {
  const _DialogAction({
    required this.label,
    required this.background,
    required this.border,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color background;
  final Color border;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return PressFeedback(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(vertical: m.s(13)),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(m.s(14)),
          border: Border.all(color: border),
        ),
        child: Text(label, style: AppText.semiBold(m.s(13), foreground)),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: const CircularProgressIndicator(
        strokeWidth: 2.2,
        color: AppColors.onGold,
      ),
    );
  }
}

class _RestoreCard extends StatelessWidget {
  const _RestoreCard({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.all(m.sc(16, 12)),
      decoration: BoxDecoration(
        color: AppColors.panelSoft,
        borderRadius: BorderRadius.circular(m.sc(14, 11)),
        border: Border.all(color: AppColors.hairlineStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.sync_rounded,
                size: m.sc(18, 16),
                color: AppColors.gold,
              ),
              SizedBox(width: m.sc(8, 6)),
              Expanded(
                child: Text(
                  'Restore a saved account',
                  style: AppText.bold(m.sc(14, 12), AppColors.textPrimary),
                ),
              ),
            ],
          ),
          SizedBox(height: m.sc(6, 4)),
          Text(
            'New phone, or reinstalled the app? Enter the account id you saved '
            'from your old device and every game comes back with it.',
            style: AppText.medium(m.sc(12, 11), AppColors.textMuted),
          ),
          SizedBox(height: m.sc(12, 10)),
          GlassPill(
            radius: m.sc(12, 12),
            onTap: busy ? null : onTap,
            padding: EdgeInsets.symmetric(
              vertical: m.sc(13, 11),
              horizontal: m.sc(14, 12),
            ),
            background: AppColors.gold,
            border: AppColors.gold,
            child: SizedBox(
              width: double.infinity,
              child: busy
                  ? Center(
                      child: SizedBox(
                        width: m.sc(18, 16),
                        height: m.sc(18, 16),
                        child: const CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: AppColors.onGold,
                        ),
                      ),
                    )
                  : Text(
                      'Enter account id',
                      textAlign: TextAlign.center,
                      style: AppText.semiBold(m.sc(13, 13), AppColors.onGold),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the account id the player saved from their other device. Returns
/// the trimmed id, or null when cancelled.
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog();

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  final _controller = TextEditingController();
  bool _valid = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      // A whole widget rebuild for a keystroke is what the "confirm stays
      // disabled until the id is plausible" rule costs, and it is cheap.
      setState(() => _valid = _uuid.hasMatch(_controller.text.trim()));
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: m.s(28)),
      // Dialog routes never move for the keyboard. Hold the panel above it and
      // let the content shrink-scroll, so in landscape — where the keys cover
      // half the screen — the id field the player is typing into stays visible.
      child: SafeArea(
        bottom: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.s(340)),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Restore your account',
                    style: AppText.bold(m.s(16), AppColors.textPrimary),
                  ),
                  SizedBox(height: m.s(6)),
                  Text(
                    'Paste the id from the Account tab of your old device — the '
                    'long string under "Account id". This device becomes that '
                    'account.',
                    style: AppText.medium(m.s(13), AppColors.textMuted),
                  ),
                  SizedBox(height: m.s(14)),
                  TextField(
                    controller: _controller,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    style: AppText.medium(m.s(13), AppColors.textPrimary),
                    cursorColor: AppColors.gold,
                    decoration: InputDecoration(
                      hintText: '018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71',
                      hintStyle: AppText.medium(m.s(13), AppColors.textFaint),
                      filled: true,
                      fillColor: AppColors.panel,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: m.s(14),
                        vertical: m.s(12),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(m.s(12)),
                        borderSide: const BorderSide(
                          color: AppColors.hairlineStrong,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(m.s(12)),
                        borderSide: const BorderSide(
                          color: AppColors.hairlineStrong,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(m.s(12)),
                        borderSide: const BorderSide(color: AppColors.gold),
                      ),
                      suffixIcon: IconButton(
                        onPressed: _paste,
                        tooltip: 'Paste',
                        icon: Icon(
                          Icons.paste_rounded,
                          size: m.s(18),
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: m.s(6)),
                  if (_controller.text.isNotEmpty && !_valid)
                    Text(
                      'That does not look like an account id.',
                      style: AppText.medium(m.s(12), AppColors.danger),
                    ),
                  SizedBox(height: m.s(18)),
                  Row(
                    children: [
                      Expanded(
                        child: PressFeedback(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            alignment: Alignment.center,
                            padding: EdgeInsets.symmetric(vertical: m.s(13)),
                            decoration: BoxDecoration(
                              color: AppColors.panel,
                              borderRadius: BorderRadius.circular(m.s(14)),
                              border: Border.all(
                                color: AppColors.hairlineStrong,
                              ),
                            ),
                            child: Text(
                              'Cancel',
                              style: AppText.semiBold(
                                m.s(13),
                                AppColors.textOnDark,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: m.s(10)),
                      Expanded(
                        child: PressFeedback(
                          onTap: _valid ? _submit : null,
                          child: Container(
                            alignment: Alignment.center,
                            padding: EdgeInsets.symmetric(vertical: m.s(13)),
                            decoration: BoxDecoration(
                              color: _valid ? AppColors.gold : AppColors.panel,
                              borderRadius: BorderRadius.circular(m.s(14)),
                              border: Border.all(
                                color: _valid
                                    ? AppColors.gold
                                    : AppColors.hairlineStrong,
                              ),
                            ),
                            child: Text(
                              'Restore',
                              style: AppText.semiBold(
                                m.s(13),
                                _valid ? AppColors.onGold : AppColors.textMuted,
                              ),
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
        ),
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.provider,
    required this.linked,
    this.onTap,
  });

  final AuthProvider provider;
  final bool linked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final enabled = onTap != null && !linked;

    return Opacity(
      // Visibly inert rather than merely unresponsive: a button that looks
      // live and does nothing when tapped reads as a bug.
      opacity: enabled ? 1.0 : 0.55,
      child: GlassPill(
        radius: m.sc(12, 12),
        onTap: enabled ? onTap : null,
        padding: EdgeInsets.symmetric(
          horizontal: m.sc(14, 12),
          vertical: m.sc(13, 11),
        ),
        background: AppColors.panel,
        border: AppColors.hairlineStrong,
        child: Row(
          children: [
            Container(
              width: m.sc(26, 24),
              height: m.sc(26, 24),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.hairline,
              ),
              child: Text(
                provider.label.substring(0, 1),
                style: AppText.bold(m.sc(12, 12), AppColors.textOnDark),
              ),
            ),
            SizedBox(width: m.sc(10, 8)),
            Expanded(
              child: Text(
                'Continue with ${provider.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.semiBold(m.sc(13, 13), AppColors.textOnDark),
              ),
            ),
            SizedBox(width: m.sc(8, 6)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: m.sc(8, 7),
                vertical: m.sc(3, 2),
              ),
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(m.sc(7, 6)),
              ),
              child: Text(
                linked ? 'Linked' : 'Coming soon',
                style: AppText.semiBold(m.sc(10, 9), AppColors.gold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpgradePromise extends StatelessWidget {
  const _UpgradePromise({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: m.s(2)),
          child: Icon(icon, size: m.sc(16, 14), color: AppColors.gold),
        ),
        SizedBox(width: m.sc(10, 8)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: AppText.semiBold(m.sc(13, 11), AppColors.textPrimary),
              ),
              SizedBox(height: m.s(2)),
              Text(
                body,
                style: AppText.medium(m.sc(12, 10), AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
