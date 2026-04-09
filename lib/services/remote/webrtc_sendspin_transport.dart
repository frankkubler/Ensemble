import 'dart:async';

import 'sendspin_transport.dart';
import 'webrtc_connection_manager.dart';

class WebRtcSendspinTransport implements SendspinTransport {
  WebRtcSendspinTransport({required this.remoteId});

  final String remoteId;
  WebRtcConnectionManager? _manager;

  @override
  String get label => 'webrtc-sendspin';

  @override
  bool get isConnected => _manager?.isConnected ?? false;

  @override
  Stream<dynamic> get messages => _manager?.sendspinMessages ?? const Stream.empty();

  @override
  Future<void> connect({
    String? url,
    Duration timeout = const Duration(seconds: 5),
    String? authToken,
    bool useProxyAuth = false,
  }) async {
    final manager = WebRtcConnectionManager(
      remoteId: remoteId,
      enableApiChannel: false,
      enableSendspinChannel: true,
    );
    _manager = manager;
    await manager.connect();
  }

  @override
  Future<void> send(String message) async {
    final manager = _manager;
    if (manager == null) {
      throw StateError('WebRTC Sendspin transport is not connected');
    }

    await manager.sendSendspinMessage(message);
  }

  @override
  Future<void> close() async {
    await _manager?.disconnect();
    _manager?.dispose();
    _manager = null;
  }
}