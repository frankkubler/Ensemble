import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum SignalingConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class SignalingClient {
  static const defaultUrl = 'wss://signaling.music-assistant.io/ws';

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final _stateController =
      StreamController<SignalingConnectionState>.broadcast();
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  SignalingConnectionState _state = SignalingConnectionState.disconnected;

  Stream<SignalingConnectionState> get connectionState =>
      _stateController.stream;
  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  SignalingConnectionState get currentState => _state;

  Future<void> connect({String url = defaultUrl}) async {
    if (_state == SignalingConnectionState.connected ||
        _state == SignalingConnectionState.connecting) {
      return;
    }

    _setState(SignalingConnectionState.connecting);

    try {
      final socket = await WebSocket.connect(url);
      _channel = IOWebSocketChannel(socket);
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (_) => _setState(SignalingConnectionState.error),
        onDone: () => _setState(SignalingConnectionState.disconnected),
      );
      _setState(SignalingConnectionState.connected);
    } catch (_) {
      _setState(SignalingConnectionState.error);
      rethrow;
    }
  }

  Future<void> sendMessage(Map<String, dynamic> message) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Signaling client is not connected');
    }

    channel.sink.add(jsonEncode(message));
  }

  Future<void> sendConnectRequest(String remoteId) async {
    await sendMessage({
      'type': 'connect-request',
      'remoteId': remoteId,
    });
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _setState(SignalingConnectionState.disconnected);
  }

  void dispose() {
    _channel = null;
    _subscription = null;
    _stateController.close();
    _messageController.close();
  }

  void _handleMessage(dynamic message) {
    if (message is! String) {
      return;
    }

    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        _messageController.add(decoded);
      }
    } catch (_) {
      // Ignore malformed signaling messages until the manager is wired in.
    }
  }

  void _setState(SignalingConnectionState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}