enum MAConnectionMode {
  direct,
  webrtc,
}

class MAConnectionContext {
  const MAConnectionContext({
    required this.endpoint,
    required this.originalServerUrl,
    required this.clientId,
    this.headers = const {},
    this.metadata = const {},
  });

  final String endpoint;
  final String originalServerUrl;
  final String clientId;
  final Map<String, String> headers;
  final Map<String, Object?> metadata;
}

typedef MAConnectionTransportBuilder = MAConnectionTransport Function(
  MAConnectionContext context,
);

abstract class MAConnectionTransport {
  MAConnectionMode get mode;
  String get label;
  bool get isConnected;
  Stream<dynamic> get messages;

  Future<void> connect(MAConnectionContext context);
  Future<void> send(String message);
  Future<void> close();
}