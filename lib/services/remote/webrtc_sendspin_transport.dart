import 'dart:async';

import 'sendspin_transport.dart';
import 'webrtc_shared_session.dart';

class WebRtcSendspinTransport implements SendspinTransport {
  WebRtcSendspinTransport({required this.remoteId});

  final String remoteId;
  WebRtcSharedSession? _session;

  @override
  String get label => 'webrtc-sendspin';

  @override
  bool get isConnected => _session?.isConnected ?? false;

  @override
  Stream<dynamic> get messages => _session?.sendspinMessages ?? const Stream.empty();

  @override
  Future<void> connect({
    String? url,
    Duration timeout = const Duration(seconds: 5),
    String? authToken,
    bool useProxyAuth = false,
  }) async {
    final session = WebRtcSharedSessionRegistry.acquire(
      remoteId,
      WebRtcSessionChannel.sendspin,
    );
    _session = session;
    await session.ensureConnected();
  }

  @override
  Future<void> send(String message) async {
    final session = _session;
    if (session == null) {
      throw StateError('WebRTC Sendspin transport is not connected');
    }

    await session.sendSendspinMessage(message);
  }

  @override
  Future<void> close() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await session.release(WebRtcSessionChannel.sendspin);
    }
  }
}