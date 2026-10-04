import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'audio/audio_controller.dart';
import 'design/motion.dart';
import 'design/tokens.dart';
import 'net/api_client.dart';
import 'net/game_uploader.dart';
import 'state/app_settings.dart';
import 'state/identity_store.dart';
import 'ui/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Storage is read once, here, so every widget below can treat the device id
  // and the session token as plain synchronous values.
  final settings = AppSettings(identity: await IdentityStore.open());

  // Offline games queued by the last run go out now. Deliberately not awaited:
  // the home screen must not wait on a network call to appear.
  GameUploader.install(await GameUploader.open(client: ApiClient.forSettings(settings)));

  runApp(CallBreakApp(settings: settings));
}

class CallBreakApp extends StatefulWidget {
  const CallBreakApp({super.key, this.settings});

  /// Built by [main] from storage. Null in tests, which get a fresh in-memory
  /// [AppSettings] instead — no plugin channels, no disk.
  final AppSettings? settings;

  @override
  State<CallBreakApp> createState() => _CallBreakAppState();
}

class _CallBreakAppState extends State<CallBreakApp> {
  late final AppSettings _settings = widget.settings ?? AppSettings();

  @override
  void initState() {
    super.initState();
    AudioController.init(_settings);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      settings: _settings,
      child: MaterialApp(
        title: 'Call Break',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF04140F),
          fontFamily: 'PlusJakartaSans',
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.gold,
            brightness: Brightness.dark,
          ),
          // One transition everywhere: the next screen fades up out of a
          // slight zoom, which reads as moving *into* the table rather than
          // sliding sideways past it.
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _FadeZoomTransitions(),
              TargetPlatform.iOS: _FadeZoomTransitions(),
              TargetPlatform.linux: _FadeZoomTransitions(),
              TargetPlatform.macOS: _FadeZoomTransitions(),
              TargetPlatform.windows: _FadeZoomTransitions(),
            },
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class _FadeZoomTransitions extends PageTransitionsBuilder {
  const _FadeZoomTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(
      parent: animation,
      curve: Motion.emphasized,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: enter,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1.0).animate(enter),
        child: child,
      ),
    );
  }
}
