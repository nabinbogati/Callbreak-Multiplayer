import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:callbreak/net/api_client.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/state/identity_store.dart';
import 'package:callbreak/ui/screens/profile_screen.dart';

/// Every tab of the profile has to answer three questions the moment it opens:
/// is it still loading, is there nothing here, or did it fail. A screen that
/// only renders the happy path is a screen that shows a blank rectangle to the
/// first player who opens it on a train.
void main() {
  const authBody =
      '{"token":"t","expiresAt":"2099-01-01T00:00:00Z",'
      '"user":{"id":"u1","displayName":"Nabin","isGuest":true,'
      '"identities":[{"provider":"device","linkedAt":"2026-08-01T12:00:00Z"}]}}';

  const statsBody =
      '{"scopes":[{"scope":"all","gamesPlayed":42,"gamesCompleted":40,'
      '"gamesWon":17,"gamesLost":23,"bestPlace":1,"handsPlayed":200,'
      '"totalBid":560,"bidsMade":141,"bidsFailed":59,"highestBid":8,'
      '"totalTricks":602,"totalScore":318.4,"highestGameScore":21.7,'
      '"lowestGameScore":-9.0,"highestHandScore":8.3,"currentWinStreak":2,'
      '"bestWinStreak":5,"lastPlayedAt":null}]}';

  /// A client whose `/v1` answers come from [answers], keyed by path fragment.
  /// The auth handshake is always answered so no test has to think about it.
  ApiClient clientFor(Map<String, (int, String)> answers) => ApiClient(
    origin: Uri.parse('https://example.test'),
    identity: IdentityStore.inMemory(),
    httpClient: MockClient((request) async {
      for (final entry in answers.entries) {
        if (request.url.path.contains(entry.key)) {
          return http.Response(entry.value.$2, entry.value.$1);
        }
      }
      return http.Response(authBody, 200);
    }),
  );

  /// A client that has not answered yet, for pinning the loading state.
  /// [releaseSilentClient] lets the request finish so the request timeout does
  /// not outlive the test.
  late Completer<http.Response> pending;

  ApiClient silentClient() {
    pending = Completer<http.Response>();
    return ApiClient(
      origin: Uri.parse('https://example.test'),
      identity: IdentityStore.inMemory()
        ..saveSession(token: 'seeded', expiresAt: DateTime.utc(2099)),
      httpClient: MockClient((_) => pending.future),
    );
  }

  Future<void> releaseSilentClient(WidgetTester tester) async {
    pending.complete(http.Response('{"scopes":[],"games":[]}', 200));
    await tester.pump();
    await tester.pump();
  }

  /// Puts the screen on a real handset-sized surface. The design is drawn at
  /// 390x844 portrait and 844x390 landscape, and both have to work.
  Future<void> pumpProfile(
    WidgetTester tester,
    ApiClient client, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      SettingsScope(
        settings: AppSettings(),
        child: MaterialApp(home: ProfileScreen(client: client)),
      ),
    );
    await tester.pump();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump();
  }

  group('the screen itself', () {
    testWidgets('opens on Statistics with all three tabs reachable', (tester) async {
      await pumpProfile(tester, clientFor({'/v1/me/stats': (200, '{"scopes":[]}')}));
      await tester.pump();

      expect(find.text('Stats'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      // The scope selector belongs to the statistics tab, which opens first.
      expect(find.text('vs Humans'), findsOneWidget);
      expect(find.text('vs Bots'), findsOneWidget);
    });

    testWidgets('lays out in landscape on a small phone without overflowing', (
      tester,
    ) async {
      // 844x390 is the design's landscape geometry; anything that overflows
      // here overflows on every phone in the app's supported orientations.
      await pumpProfile(
        tester,
        clientFor({'/v1/me/stats': (200, statsBody)}),
        size: const Size(844, 390),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Landscape has the width for the full tab titles.
      expect(find.text('Upgrade Account'), findsOneWidget);
      expect(find.text('43%'), findsOneWidget);
    });
  });

  group('Statistics tab', () {
    testWidgets('shows a spinner while the first request is in flight', (
      tester,
    ) async {
      await pumpProfile(tester, silentClient());

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await releaseSilentClient(tester);
    });

    testWidgets('renders the figures it derives from the counters', (tester) async {
      await pumpProfile(tester, clientFor({'/v1/me/stats': (200, statsBody)}));
      await tester.pump();

      expect(find.text('43%'), findsOneWidget); // 17/40 win rate
      expect(find.text('17W · 23L'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('1st'), findsOneWidget);
      expect(find.text('71%'), findsOneWidget); // 141/200 bid accuracy
      expect(find.text('8.3'), findsOneWidget); // highest hand score
      // lastPlayedAt was null, so the row is absent rather than dated.
      expect(find.textContaining('Last played'), findsNothing);
    });

    testWidgets('a scope never played invites rather than showing zeros', (
      tester,
    ) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (
            200,
            '{"scopes":[{"scope":"all","gamesPlayed":3},'
                '{"scope":"private","gamesPlayed":0,"lastPlayedAt":null}]}',
          ),
        }),
      );
      await tester.pump();

      await openTab(tester, 'Private');

      expect(find.text('Nothing in Private yet'), findsOneWidget);
      expect(find.textContaining('Play a Private game'), findsOneWidget);
    });

    testWidgets('a failure explains itself and offers a retry', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (
            500,
            '{"error":{"code":"internal","message":"Something broke."}}',
          ),
        }),
      );
      await tester.pump();

      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('Something broke.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('persistence_disabled is a state, not a red error screen', (
      tester,
    ) async {
      // A server with no DATABASE_URL is a supported deployment. Nothing is
      // wrong, so nothing is offered to retry.
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (
            503,
            '{"error":{"code":"persistence_disabled",'
                '"message":"No database configured."}}',
          ),
        }),
      );
      await tester.pump();

      expect(find.text('History is off on this server'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  group('Game History tab', () {
    testWidgets('shows a spinner while the first page is in flight', (tester) async {
      await pumpProfile(tester, silentClient());
      await openTab(tester, 'History');

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await releaseSilentClient(tester);
    });

    testWidgets('an empty history invites a first game', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me/games': (200, '{"games":[],"nextCursor":""}'),
        }),
      );
      await openTab(tester, 'History');

      expect(find.text('No games yet'), findsOneWidget);
    });

    testWidgets('a game renders its placing, score and opponents', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me/games': (
            200,
            '{"games":[{"id":"g1","mode":"bots","completed":true,'
                '"startedAt":"2026-08-10T09:10:00Z",'
                '"finishedAt":"2026-08-10T09:34:11Z","handsTotal":5,'
                '"you":{"seat":2,"finalScore":13.2,"place":1},'
                '"players":['
                '{"seat":0,"displayName":"Amit","isBot":true,"place":3},'
                '{"seat":2,"displayName":"Nabin","isBot":false,"place":1},'
                '{"seat":3,"displayName":"Sujan","isBot":true,"place":4}'
                ']}],"nextCursor":""}',
          ),
        }),
      );
      await openTab(tester, 'History');

      expect(find.text('1st'), findsOneWidget);
      expect(find.text('13.2'), findsOneWidget);
      expect(find.text('vs Bots'), findsWidgets);
      expect(find.text('Amit · Sujan'), findsOneWidget);
    });

    testWidgets('tapping a row opens the hand-by-hand scoreboard', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me/games': (
            200,
            '{"games":[{"id":"g1","mode":"bots","completed":true,'
                '"finishedAt":"2026-08-10T09:34:11Z","handsTotal":2,'
                '"you":{"seat":0,"finalScore":6.0,"place":1},'
                '"players":['
                '{"seat":0,"displayName":"Nabin","finalScore":6.0,"place":1},'
                '{"seat":1,"displayName":"Amit","finalScore":-4.0,"place":2}'
                ']}],"nextCursor":""}',
          ),
          '/v1/games/g1': (
            200,
            '{"game":{"id":"g1","mode":"bots","handsTotal":2,'
                '"you":{"seat":0,"finalScore":6.0,"place":1},'
                '"players":['
                '{"seat":0,"displayName":"Nabin","finalScore":6.0,"place":1},'
                '{"seat":1,"displayName":"Amit","finalScore":-4.0,"place":2}'
                ']},'
                '"hands":['
                '{"handIndex":0,"seat":0,"bid":3,"tricksWon":3,'
                '"scoreDelta":3.0,"runningTotal":3.0},'
                '{"handIndex":0,"seat":1,"bid":4,"tricksWon":2,'
                '"scoreDelta":-4.0,"runningTotal":-4.0}]}',
          ),
        }),
      );
      await openTab(tester, 'History');

      await tester.tap(find.text('Amit'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The same Rnd | seat columns the in-game round history uses.
      expect(find.text('Rnd'), findsOneWidget);
      expect(find.text('3.0'), findsOneWidget); // seat 0's delta
      // Twice: the scorecard's totals row, and the history row still behind
      // the dialog.
      expect(find.text('6.0'), findsNWidgets(2));
      // Seat 1 scored -4.0 on its only recorded hand and finished on -4.0, so
      // the number appears once as a delta and once in the totals row.
      expect(find.text('-4.0'), findsNWidgets(2));
      expect(find.text('3 bid · 3 won'), findsOneWidget);
      expect(find.text('4 bid · 2 won'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
    });

    testWidgets('a failure explains itself and offers a retry', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me/games': (
            502,
            '{"error":{"code":"internal","message":"Upstream is down."}}',
          ),
        }),
      );
      await openTab(tester, 'History');

      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('Upstream is down.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('Upgrade Account tab', () {
    testWidgets('shows a spinner while the profile is in flight', (tester) async {
      await pumpProfile(tester, silentClient());
      await openTab(tester, 'Account');

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await releaseSilentClient(tester);
    });

    testWidgets('a guest sees three disabled providers and both promises', (
      tester,
    ) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (
            200,
            '{"user":{"id":"u1","displayName":"Nabin","isGuest":true,'
                '"identities":[{"provider":"device"}]}}',
          ),
        }),
      );
      await openTab(tester, 'Account');

      expect(find.text('Guest account'), findsWidgets);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Facebook'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
      // The flag is off, so every button says so rather than doing nothing.
      expect(find.text('Coming soon'), findsNWidgets(3));

      // The two concrete promises, not vague marketing — scrolled to, because
      // the account id and restore cards sit above them on the same list.
      await tester.scrollUntilVisible(
        find.text('The same account on any device'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Nothing is lost'), findsOneWidget);
      expect(find.text('The same account on any device'), findsOneWidget);
      expect(find.textContaining('sign-in method that carries it'), findsOneWidget);
    });

    testWidgets('a linked account names the provider it is signed in with', (
      tester,
    ) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (
            200,
            '{"user":{"id":"u1","displayName":"Nabin","isGuest":false,'
                '"identities":[{"provider":"device"},{"provider":"google"}]}}',
          ),
        }),
      );
      await openTab(tester, 'Account');

      expect(find.text('Signed in'), findsOneWidget);
      expect(find.text('Signed in with Google.'), findsOneWidget);
      expect(find.text('Linked'), findsOneWidget);
    });

    testWidgets('a stale profile still shows what linking would buy', (tester) async {
      // None of this copy depends on the network, and a player deciding
      // whether to sign in is exactly the player who cannot reach the server.
      // The cached profile from the session handshake carries the identity.
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (500, '{"error":{"code":"internal","message":"Down."}}'),
        }),
      );
      await openTab(tester, 'Account');

      expect(find.text('Guest account'), findsWidgets);
      expect(find.text('Nothing is lost'), findsOneWidget);
      expect(find.text('Coming soon'), findsNWidgets(3));
    });

    testWidgets('with nothing cached at all it explains and offers a retry', (
      tester,
    ) async {
      // Every call fails, including the session handshake, so there is no
      // profile to fall back on — the one case that takes over the tab.
      await pumpProfile(
        tester,
        ApiClient(
          origin: Uri.parse('https://example.test'),
          identity: IdentityStore.inMemory(),
          httpClient: MockClient(
            (_) async => http.Response(
              '{"error":{"code":"internal","message":"Down."}}',
              500,
            ),
          ),
        ),
      );
      await openTab(tester, 'Account');

      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('Down.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a guest sees their account id and the restore entry point', (
      tester,
    ) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (
            200,
            '{"user":{"id":"u1","displayName":"Nabin","isGuest":true,'
                '"identities":[{"provider":"device"}]}}',
          ),
        }),
      );
      await openTab(tester, 'Account');

      // The copyable account id row from the previous change.
      expect(find.text('Account id'), findsOneWidget);
      expect(find.text('u1'), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

      // And the path back from a new phone.
      expect(find.text('Restore a saved account'), findsOneWidget);
      expect(find.text('Enter account id'), findsOneWidget);
    });

    testWidgets('a linked account is not offered a restore', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (
            200,
            '{"user":{"id":"u1","displayName":"Nabin","isGuest":false,'
                '"identities":[{"provider":"device"},{"provider":"google"}]}}',
          ),
        }),
      );
      await openTab(tester, 'Account');

      expect(find.text('Restore a saved account'), findsNothing);
      // Signing in is the restore for a linked account.
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('restoring a saved account brings its history in', (tester) async {
      const saved =
          '{"id":"saved-1","displayName":"Veteran","isGuest":true,'
          '"identities":[{"provider":"device"}]}';
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (200, '{"user":$saved}'),
          '/v1/auth/restore': (
            200,
            '{"token":"rt","expiresAt":"2099-01-01T00:00:00Z","user":$saved}',
          ),
        }),
      );
      await openTab(tester, 'Account');

      await tester.tap(find.text('Enter account id'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The confirm stays disabled until the id is a plausible uuid.
      await tester.tap(find.text('Restore'));
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(1));

      await tester.enterText(
        find.byType(TextField),
        '018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71',
      );
      await tester.pump();

      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // The dialog is gone, the restored account owns the tab, and the player
      // is told so.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Welcome back, Veteran. Your history is restored on this device.'), findsOneWidget);
      expect(find.text('saved-1'), findsWidgets);
    });

    testWidgets('a bad account id is refused quietly', (tester) async {
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (
            200,
            '{"user":{"id":"u1","displayName":"Nabin","isGuest":true,'
                '"identities":[{"provider":"device"}]}}',
          ),
          // The server's own answer for an id that names nobody.
          '/v1/auth/restore': (
            404,
            '{"error":{"code":"not_found","message":"No guest account has that id."}}',
          ),
        }),
      );
      await openTab(tester, 'Account');

      await tester.tap(find.text('Enter account id'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byType(TextField),
        '018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71',
      );
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The rejection is a snackbar from the server, not a crash or a dead
      // screen, and the account is unchanged.
      expect(find.text('No guest account has that id.'), findsOneWidget);
      expect(find.text('u1'), findsWidgets);
    });

    testWidgets('a restore that left games behind offers to bring them along', (
      tester,
    ) async {
      const saved =
          '{"id":"saved-1","displayName":"Veteran","isGuest":true,'
          '"identities":[{"provider":"device"}]}';
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (200, '{"user":$saved}'),
          '/v1/auth/restore': (
            200,
            '{"token":"rt","expiresAt":"2099-01-01T00:00:00Z","user":$saved,'
                '"abandoned":{"accountId":"abandoned-1","games":2}}',
          ),
          '/v1/me/merge/': (200, '{"user":$saved}'),
        }),
      );
      await openTab(tester, 'Account');

      await tester.tap(find.text('Enter account id'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byType(TextField),
        '018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71',
      );
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();

      // The same moment the restore succeeds, the decision is asked.
      expect(find.text('Games from your old device'), findsOneWidget);
      expect(find.textContaining('still has 2 games'), findsOneWidget);

      // Let the welcome snackbar's time pass so the merge announcement is the
      // one on screen, not one queued behind it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Bring them along'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // The games joined the restored history, the offer is consumed, and the
      // player is told so.
      expect(find.text('Your 2 games joined your history.'), findsOneWidget);
      expect(find.text('Games from your old device'), findsNothing);
      expect(find.text('Games from your old install'), findsNothing);
    });

    testWidgets('a restore that left games behind can leave them behind', (
      tester,
    ) async {
      const saved =
          '{"id":"saved-1","displayName":"Veteran","isGuest":true,'
          '"identities":[{"provider":"device"}]}';
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (200, '{"user":$saved}'),
          '/v1/auth/restore': (
            200,
            '{"token":"rt","expiresAt":"2099-01-01T00:00:00Z","user":$saved,'
                '"abandoned":{"accountId":"abandoned-1","games":2}}',
          ),
          '/v1/me/abandoned/': (204, ''),
        }),
      );
      await openTab(tester, 'Account');

      await tester.tap(find.text('Enter account id'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byType(TextField),
        '018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71',
      );
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Leave them behind'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(
        find.text('Those games were left behind. The restored account keeps its own history.'),
        findsOneWidget,
      );
      expect(find.text('Games from your old install'), findsNothing);
    });

    testWidgets('an undecided offer stays as a card and can be merged later', (
      tester,
    ) async {
      const saved =
          '{"id":"saved-1","displayName":"Veteran","isGuest":true,'
          '"identities":[{"provider":"device"}]}';
      await pumpProfile(
        tester,
        clientFor({
          '/v1/me/stats': (200, '{"scopes":[]}'),
          '/v1/me': (200, '{"user":$saved}'),
          '/v1/auth/restore': (
            200,
            '{"token":"rt","expiresAt":"2099-01-01T00:00:00Z","user":$saved,'
                '"abandoned":{"accountId":"abandoned-1","games":1}}',
          ),
          '/v1/me/merge/': (200, '{"user":$saved}'),
        }),
      );
      await openTab(tester, 'Account');

      await tester.tap(find.text('Enter account id'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byType(TextField),
        '018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71',
      );
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();

      // Putting the decision off leaves the dialog open only until "Decide
      // later" is tapped, and the offer lives on as a card.
      await tester.tap(find.text('Decide later'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Games from your old install'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      // The card's own decision does the merge without re-asking.
      await tester.tap(find.text('Bring them along'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('Your 1 game joined your history.'), findsOneWidget);
      expect(find.text('Games from your old install'), findsNothing);
    });
  });
}
