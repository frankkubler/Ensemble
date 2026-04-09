import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'sendspin_transport.dart';

class WebSocketSendspinTransport implements SendspinTransport {
  final _messageController = StreamController<dynamic>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  @override
  String get label => 'websocket-sendspin';

  @override
  bool get isConnected => _channel != null;

  @override
  Stream<dynamic> get messages => _messageController.stream;

  @override
  Future<void> connect({
    String? url,
    Duration timeout = const Duration(seconds: 5),
    String? authToken,
    bool useProxyAuth = false,
  }) async {
    if (url == null || url.isEmpty) {
      throw ArgumentError('WebSocket Sendspin transport requires a URL');
    }

    final webSocket = await WebSocket.connect(url).timeout(timeout);
    _channel = IOWebSocketChannel(webSocket);
    _subscription = _channel!.stream.listen(
      (message) {
        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
      },
      onError: (error, stackTrace) {
        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!_messageController.isClosed) {
          _messageController.close();
        }
      },
    );
  }

  @override
  Future<void> send(String message) async {
    _channel?.sink.add(message);
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    if (!_messageController.isClosed) {
      await _messageController.close();
    }
  }
}