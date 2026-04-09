import 'dart:async';

abstract class SendspinTransport {
  String get label;
  bool get isConnected;
  Stream<dynamic> get messages;

  Future<void> connect({
    String? url,
    Duration timeout = const Duration(seconds: 5),
    String? authToken,
    bool useProxyAuth = false,
  });

  Future<void> send(String message);
  Future<void> close();
}

typedef SendspinTransportBuilder = SendspinTransport Function();