import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/audio/audio_controller.dart';
import 'package:callbreak/state/app_settings.dart';

/// Stands in for the native plugin and counts what the game asks of it.
class _FakePlatform extends AudioplayersPlatformInterface {
  final created = <String>[];
  final disposed = <String>[];
  var sourcesSet = 0;
  var resumes = 0;
  final _events = <String, StreamController<AudioEvent>>{};

  @override
  Future<void> create(String playerId) async {
    created.add(playerId);
    _events[playerId] = StreamController<AudioEvent>.broadcast();
  }

  @override
  Future<void> dispose(String playerId) async => disposed.add(playerId);

  @override
  Stream<AudioEvent> getEventStream(String playerId) => _events[playerId]!.stream;

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    sourcesSet++;
    // A real player reports itself prepared once the sound has loaded.
    scheduleMicrotask(
      () => _events[playerId]!.add(
        const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
      ),
    );
  }

  @override
  Future<void> resume(String playerId) async => resumes++;

  @override
  Future<void> stop(String playerId) async {}
  @override
  Future<void> pause(String playerId) async {}
  @override
  Future<void> release(String playerId) async {}
  @override
  Future<void> seek(String playerId, Duration position) async {}
  @override
  Future<void> setBalance(String playerId, double balance) async {}
  @override
  Future<void> setVolume(String playerId, double volume) async {}
  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async {}
  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async {}
  @override
  Future<void> setSourceBytes(String playerId, Uint8List bytes, {String? mimeType}) async {}
  @override
  Future<void> setAudioContext(String playerId, AudioContext audioContext) async {}
  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) async {}
  @override
  Future<int?> getDuration(String playerId) async => null;
  @override
  Future<int?> getCurrentPosition(String playerId) async => null;
  @override
  Future<void> emitLog(String playerId, String message) async {}
  @override
  Future<void> emitError(String playerId, String code, String message) async {}
}

class _FakeGlobalPlatform extends GlobalAudioplayersPlatformInterface {
  @override
  Future<void> init() async {}
  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}
  @override
  Future<void> emitGlobalLog(String message) async {}
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
}

/// Skips copying the asset to a temporary file, which needs a real device.
class _FakeCache extends AudioCache {
  @override
  Future<String> loadPath(String fileName) async => '/tmp/$fileName';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('card sounds reuse a fixed set of players instead of one per sound', () async {
    final platform = _FakePlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobalPlatform();
    AudioCache.instance = _FakeCache();

    AudioController.init(AppSettings()..musicEnabled = false);
    final audio = AudioController.instance!;

    // A full hand's worth of table sounds: 52 cards, 13 tricks, some trumps.
    for (var i = 0; i < 52; i++) {
      audio.playShot();
      if (i % 4 == 3) audio.playCollect();
      if (i % 9 == 0) audio.playTrump();
      await pumpEventQueue();
    }
    // The collect sound starts a beat after the trick is decided.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pumpEventQueue();

    expect(
      platform.resumes,
      52 + 13 + 6,
      reason: 'every sound still plays',
    );
    expect(
      platform.created.length,
      lessThanOrEqualTo(6),
      reason: 'a handful of reusable voices, not a native player per sound '
          '(the low-latency backend never reports completion, so per-sound '
          'players could never be disposed)',
    );
    expect(
      platform.sourcesSet,
      platform.created.length,
      reason: 'each voice loads its sound once',
    );
  });
}
