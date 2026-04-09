import 'dart:async';

import 'ma_connection_transport.dart';
import 'webrtc_shared_session.dart';

class WebRtcApiTransport implements MAConnectionTransport {
  WebRtcApiTransport({required this.remoteId});

  final String remoteId;
  WebRtcSharedSession? _session;

  @override
  MAConnectionMode get mode => MAConnectionMode.webrtc;

  @override
  String get label => 'webrtc-ma-api';

  @override
  bool get isConnected => _session?.isConnected ?? false;

  @override
  Stream<dynamic> get messages => _session?.apiMessages ?? const Stream.empty();

  @override
  Future<void> connect(MAConnectionContext context) async {
    final session = WebRtcSharedSessionRegistry.acquire(
      remoteId,
      WebRtcSessionChannel.api,
    );
    _session = session;
    try {
      await session.ensureConnected();
    } catch (_) {
      _session = null;
      await session.release(WebRtcSessionChannel.api);
      rethrow;
    }
  }

  @override
  Future<void> send(String message) async {
    final session = _session;
    if (session == null) {
      throw StateError('WebRTC transport is not connected');
    }

    await session.sendApiMessage(message);
  }

  @override
  Future<void> close() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await session.release(WebRtcSessionChannel.api);
    }
  }
}