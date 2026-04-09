import 'dart:async';

import 'ma_connection_transport.dart';
import 'webrtc_connection_manager.dart';

class WebRtcApiTransport implements MAConnectionTransport {
  WebRtcApiTransport({required this.remoteId});

  final String remoteId;
  WebRtcConnectionManager? _manager;

  @override
  MAConnectionMode get mode => MAConnectionMode.webrtc;

  @override
  String get label => 'webrtc-ma-api';

  @override
  bool get isConnected => _manager?.isConnected ?? false;

  @override
  Stream<dynamic> get messages => _manager?.messages ?? const Stream.empty();

  @override
  Future<void> connect(MAConnectionContext context) async {
    final manager = WebRtcConnectionManager(remoteId: remoteId);
    _manager = manager;
    await manager.connect();
  }

  @override
  Future<void> send(String message) async {
    final manager = _manager;
    if (manager == null) {
      throw StateError('WebRTC transport is not connected');
    }

    await manager.sendApiMessage(message);
  }

  @override
  Future<void> close() async {
    await _manager?.disconnect();
    _manager?.dispose();
    _manager = null;
  }
}