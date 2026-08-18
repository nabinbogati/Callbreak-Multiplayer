import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Fixed UDP port both sides use to find each other. Plain broadcast (not
/// multicast), so no extra Android multicast permission is needed.
const int lanDiscoveryPort = 47777;

/// How long an advert is trusted after its last sighting before it is pruned
/// from [LanDiscovery.games].
const Duration _advertTtl = Duration(seconds: 4);

/// One host's advertised table, as seen by a listening device.
class LanGameAdvert {
  const LanGameAdvert({
    required this.roomCode,
    required this.hostName,
    required this.address,
    required this.wsPort,
    required this.playerCount,
    this.maxPlayers = 4,
  });

  final String roomCode;
  final String hostName;
  final InternetAddress address;
  final int wsPort;
  final int playerCount;
  final int maxPlayers;

  String get wsUrl => 'ws://${address.address}:$wsPort';
}

/// Host side: periodically broadcasts this table so LanDiscovery listeners
/// on the same network can find it, until [stop] is called.
class LanBroadcaster {
  LanBroadcaster({
    required this.roomCode,
    required this.hostName,
    required this.wsPort,
    this.interval = const Duration(seconds: 1),
  });

  final String roomCode;
  final String hostName;
  final int wsPort;
  final Duration interval;

  RawDatagramSocket? _socket;
  Timer? _timer;
  int _playerCount = 1;

  void updatePlayerCount(int count) => _playerCount = count;

  Future<void> start() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    _socket = socket;
    _timer = Timer.periodic(interval, (_) => _sendOnce());
    _sendOnce();
  }

  void _sendOnce() {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(
      jsonEncode({
        'type': 'callbreak-lan',
        'room': roomCode,
        'host': hostName,
        'port': wsPort,
        'players': _playerCount,
      }),
    );
    socket.send(payload, InternetAddress('255.255.255.255'), lanDiscoveryPort);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _socket?.close();
  }
}

/// Client side: listens for LanBroadcaster packets and maintains a live list
/// of currently-visible games, pruning ones not seen recently.
class LanDiscovery extends ChangeNotifier {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _pruneTimer;

  final Map<String, (LanGameAdvert, DateTime)> _seen = {};

  /// Currently-visible games, most recently seen first.
  List<LanGameAdvert> get games {
    final entries = _seen.values.toList()..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final e in entries) e.$1];
  }

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      lanDiscoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _subscription = socket.listen(_onEvent);
    _pruneTimer = Timer.periodic(const Duration(seconds: 1), (_) => _prune());
  }

  void _onEvent(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null || event != RawSocketEvent.read) return;

    final datagram = socket.receive();
    if (datagram == null) return;

    Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(utf8.decode(datagram.data)) as Map);
    } catch (_) {
      return;
    }
    if (message['type'] != 'callbreak-lan') return;

    final room = message['room'] as String?;
    final host = message['host'] as String?;
    final port = message['port'] as int?;
    if (room == null || host == null || port == null) return;

    final advert = LanGameAdvert(
      roomCode: room,
      hostName: host,
      address: datagram.address,
      wsPort: port,
      playerCount: message['players'] as int? ?? 1,
    );

    final key = '${datagram.address.address}:$room';
    _seen[key] = (advert, DateTime.now());
    notifyListeners();
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(_advertTtl);
    final before = _seen.length;
    _seen.removeWhere((_, entry) => entry.$2.isBefore(cutoff));
    if (_seen.length != before) notifyListeners();
  }

  Future<void> stop() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _seen.clear();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
