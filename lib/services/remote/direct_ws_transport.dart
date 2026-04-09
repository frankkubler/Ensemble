import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ma_connection_transport.dart';

class DirectWsTransport implements MAConnectionTransport {
  WebSocketChannel? _channel;

  @override
  MAConnectionMode get mode => MAConnectionMode.direct;

  @override
  String get label => 'direct-ws';

  @override
  bool get isConnected => _channel != null;

  @override
  Stream<dynamic> get messages => _channel?.stream ?? const Stream.empty();

  @override
  Future<void> connect(MAConnectionContext context) async {
    final webSocket = await WebSocket.connect(
      context.endpoint,
      headers: context.headers.isNotEmpty ? context.headers : null,
    );
    _channel = IOWebSocketChannel(webSocket);
  }

  @override
  Future<void> send(String message) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Direct WebSocket transport is not connected');
    }

    channel.sink.add(message);
  }

  @override
  Future<void> close() async {
    await _channel?.sink.close();
    _channel = null;
  }
}