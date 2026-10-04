import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';

import '../state/app_settings.dart';

/// App-wide sound: a looping background track plus one-shot card sounds.
///
/// One instance is created by [AudioController.init] in main.dart and lives for
/// the process; everything else reaches it through [instance]. It mirrors the
/// [AppSettings] toggles — flipping "Background music" or "Sound effects" in
/// the settings sheet takes effect immediately. Every underlying player call
/// is guarded so a missing or failing audio plugin can never crash the game.
class AudioController with WidgetsBindingObserver {
  AudioController._(this._settings) : _lastMusic = _settings.musicEnabled {
    _settings.addListener(_onSettingsChanged);
    unawaited(_syncMusic());
  }

  /// The process-wide controller, null until the app calls [init].
  static AudioController? instance;

  /// Binds the singleton to [settings] and starts the soundtrack if enabled.
  static void init(AppSettings settings) {
    instance ??= AudioController._(settings);
    WidgetsBinding.instance.addObserver(instance!);
  }

  /// True while the soundtrack is only silenced because the app left the
  /// foreground, so arriving back resumes it instead of treating it as a
  /// settings change. Music the player never enabled is never touched.
  bool _musicPausedForLifecycle = false;

  static final _bgMusic = AssetSource('audio/music.mp3');
  static final _cardShot = AssetSource('audio/card_thrown.mp3');
  static final _collect = AssetSource('audio/woosh.mp3');
  static final _trump = AssetSource('audio/trump_play.mp3');
  static final _tick = AssetSource('audio/ticking-sound.wav');
  static final _deal = AssetSource('audio/card_thrown.mp3');

  /// Background music sits well under the table's own sounds.
  static const _musicVolume = 0.4;

  /// The clock tick is a nag, not an event — loud enough to notice, quiet
  /// enough to sit under a card landing.
  static const _tickVolume = 0.55;

  /// The dealing loop sits under the deal the same way the tick sits under a
  /// countdown: audible as a rhythm, not loud enough to bury a card shot.
  static const _dealVolume = 0.7;

  /// The deal card sound is a short single swish; looped at its natural speed
  /// it lags a 55ms-per-card deal, so it is played faster to keep time.
  static const _dealRate = 3.0;

  final AppSettings _settings;

  /// Reusable voices for the short effects — see [_Voices] for why a fresh
  /// player per sound is not an option.
  late final _shotVoices = _Voices(_cardShot, 3);
  late final _collectVoices = _Voices(_collect, 2);
  late final _trumpVoices = _Voices(_trump, 1);

  AudioPlayer? _musicPlayer;
  AudioPlayer? _tickPlayer;
  AudioPlayer? _dealPlayer;
  bool _lastMusic;

  void _onSettingsChanged() {
    if (_settings.musicEnabled == _lastMusic) return;
    _lastMusic = _settings.musicEnabled;
    unawaited(_syncMusic());
  }

  Future<void> _syncMusic() async {
    try {
      if (_settings.musicEnabled) {
        final player = _musicPlayer ??= AudioPlayer()..setReleaseMode(ReleaseMode.loop);
        await player.play(_bgMusic, volume: _musicVolume);
      } else {
        await _musicPlayer?.stop();
      }
    } catch (_) {
      // Audio unavailable (tests, headless platforms) — stay silent.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // The app is off-screen, so a looping soundtrack would keep playing to
        // nothing (or into the player's next app). Silence it, cheap either
        // way: pausing a stopped or absent player is a no-op.
        if (_musicPausedForLifecycle) return;
        _musicPausedForLifecycle = true;
        unawaited(_pauseMusic());
      case AppLifecycleState.resumed:
        if (!_musicPausedForLifecycle) return;
        _musicPausedForLifecycle = false;
        unawaited(_resumeMusic());
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _pauseMusic() async {
    try {
      await _musicPlayer?.pause();
    } catch (_) {
      // Audio unavailable — stay silent.
    }
  }

  Future<void> _resumeMusic() async {
    if (!_settings.musicEnabled) return;
    try {
      await _musicPlayer?.resume();
    } catch (_) {
      // Audio unavailable — stay silent.
    }
  }

  /// The card-hits-the-table sound.
  void playShot() => unawaited(_oneShot(_shotVoices));

  /// Starts the dealing flourish: the card sound loops for the whole deal, so
  /// each card leaving the deck keeps time with the audio. Stops with
  /// [stopDeal] once the deal finishes.
  void playDeal() => unawaited(_startDeal());

  /// Ends the looping deal sound started by [playDeal]. Safe to call when
  /// nothing is playing, and called on every deal boundary so a deal that
  /// moved on never leaves its loop behind.
  void stopDeal() => unawaited(_stopDeal());

  Future<void> _startDeal() async {
    if (!_settings.sfxEnabled) return;
    try {
      final player = _dealPlayer ??= AudioPlayer()..setReleaseMode(ReleaseMode.loop);
      // The card sound is a single swish; at normal speed the loop drags
      // behind a 55ms-per-card deal, so play it faster to keep time.
      await player.setPlaybackRate(_dealRate);
      await player.play(_deal, volume: _dealVolume, mode: PlayerMode.lowLatency);
    } catch (_) {
      // Audio unavailable — the deal is still visible, which is the part that
      // matters.
    }
  }

  Future<void> _stopDeal() async {
    try {
      await _dealPlayer?.stop();
    } catch (_) {
      // Audio unavailable — nothing to stop.
    }
  }

  /// The winner-takes-the-trick collect sound, brief so it never smothers a
  /// card still landing.
  void playCollect() {
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 110), () async {
        await _oneShot(_collectVoices);
      }),
    );
  }

  /// The flourish for a trump landing into a trick led by a normal (non-trump)
  /// suit — the moment the lead suit stops mattering. Plays alongside the card
  /// shot the table already fires.
  void playTrump() => unawaited(_oneShot(_trumpVoices));

  /// Starts the turn clock's ticking, once a player's countdown enters its
  /// alarm window. The sample is a continuous ticking loop, so it plays for
  /// the whole window rather than being re-triggered on the beat — restarting
  /// it every second would saw the loop into stutter.
  void startTick() => unawaited(_startTick());

  /// Ends the ticking started by [startTick]. Safe to call when nothing is
  /// playing, and called on every turn boundary so a clock that moved on never
  /// leaves its tick behind.
  void stopTick() => unawaited(_stopTick());

  Future<void> _startTick() async {
    if (!_settings.sfxEnabled) return;
    try {
      final player = _tickPlayer ??= AudioPlayer()..setReleaseMode(ReleaseMode.loop);
      await player.play(_tick, volume: _tickVolume, mode: PlayerMode.lowLatency);
    } catch (_) {
      // Audio unavailable — the countdown is still on screen, which is the
      // part that matters.
    }
  }

  Future<void> _stopTick() async {
    try {
      await _tickPlayer?.stop();
    } catch (_) {
      // Audio unavailable — nothing to stop.
    }
  }

  Future<void> _oneShot(_Voices voices) async {
    if (!_settings.sfxEnabled) return;
    await voices.play();
  }
}

/// A few low-latency players for one short sound effect, created once and
/// replayed round-robin.
///
/// Each play used to create a brand-new [AudioPlayer] and dispose it on
/// `onPlayerComplete`. In low-latency mode (Android's SoundPool) the plugin
/// never reports completion, so that dispose was never reached: every card
/// played, trick collected and trump landed leaked a native player and its
/// event channel — several hundred per game, for the life of the process.
/// Calling `play(source)` again on one player is no cure either, since every
/// call re-registers the player against the sound in the plugin. So the source
/// is set once, and each play is a stop (rewinds the SoundPool stream) then a
/// resume. [count] voices let quick successive shots overlap, as fresh players
/// did.
class _Voices {
  _Voices(this.source, this.count);

  final Source source;
  final int count;
  final _players = <AudioPlayer>[];
  Future<void>? _ready;
  var _next = 0;

  Future<void> _prepare() async {
    try {
      for (var i = 0; i < count; i++) {
        final player = AudioPlayer();
        _players.add(player);
        await player.setPlayerMode(PlayerMode.lowLatency);
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSource(source);
      }
    } catch (_) {
      // Audio unavailable. Drop the half-built voices so a later play can try
      // again from scratch.
      final built = [..._players];
      _players.clear();
      _ready = null;
      for (final player in built) {
        try {
          await player.dispose();
        } catch (_) {
          // Nothing else to do — a sound must never crash the game.
        }
      }
      rethrow;
    }
  }

  Future<void> play() async {
    try {
      await (_ready ??= _prepare());
      if (_players.isEmpty) return;
      final player = _players[_next];
      _next = (_next + 1) % _players.length;
      await player.stop();
      await player.resume();
    } catch (_) {
      // A sound must never crash the game.
    }
  }
}
