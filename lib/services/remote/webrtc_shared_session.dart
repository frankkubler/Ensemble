import 'dart:async';

import '../debug_logger.dart';
import 'webrtc_connection_manager.dart';

enum WebRtcSessionChannel {
  api,
  sendspin,
}

class WebRtcSharedSessionRegistry {
  static final Map<String, WebRtcSharedSession> _sessions = {};

  static WebRtcSharedSession acquire(String remoteId, WebRtcSessionChannel channel) {
    final normalizedRemoteId = remoteId.trim().toUpperCase();
    final session = _sessions.putIfAbsent(
      normalizedRemoteId,
      () => WebRtcSharedSession._(
        remoteId: normalizedRemoteId,
        onReleased: () => _sessions.remove(normalizedRemoteId),
      ),
    );
    session._acquire(channel);
    return session;
  }
}

class WebRtcSharedSession {
  WebRtcSharedSession._({
    required this.remoteId,
    required VoidCallback onReleased,
  }) : _onReleased = onReleased;

  final String remoteId;
  final VoidCallback _onReleased;
  final _logger = DebugLogger();

  final _apiMessagesController = StreamController<dynamic>.broadcast();
  final _sendspinMessagesController = StreamController<dynamic>.broadcast();

  WebRtcConnectionManager? _manager;
  StreamSubscription<dynamic>? _apiSubscription;
  StreamSubscription<dynamic>? _sendspinSubscription;
  StreamSubscription<WebRtcConnectionState>? _stateSubscription;
  Completer<void>? _connectInProgress;
  Timer? _reconnectTimer;

  int _apiRefCount = 0;
  int _sendspinRefCount = 0;
  bool _disposed = false;
  bool _manualShutdown = false;
  int _reconnectAttempts = 0;

  Stream<dynamic> get apiMessages => _apiMessagesController.stream;
  Stream<dynamic> get sendspinMessages => _sendspinMessagesController.stream;
  bool get hasListeners => _apiRefCount > 0 || _sendspinRefCount > 0;
  bool get isConnected => _manager?.isConnected ?? false;

  void _acquire(WebRtcSessionChannel channel) {
    switch (channel) {
      case WebRtcSessionChannel.api:
        _apiRefCount++;
        break;
      case WebRtcSessionChannel.sendspin:
        _sendspinRefCount++;
        break;
    }

    _logger.log(
      'WebRTC shared session [$remoteId]: acquired ${channel.name} '
      '(api=$_apiRefCount, sendspin=$_sendspinRefCount)',
    );
  }

  Future<void> ensureConnected() async {
    if (_disposed) {
      throw StateError('WebRTC shared session is disposed');
    }

    _manualShutdown = false;

    if (_manager?.isConnected ?? false) {
      _logger.log('WebRTC shared session [$remoteId]: already connected');
      return;
    }

    final pending = _connectInProgress;
    if (pending != null && !pending.isCompleted) {
      return pending.future;
    }

    final completer = Completer<void>();
    _connectInProgress = completer;

    try {
      _logger.log(
        'WebRTC shared session [$remoteId]: connecting '
        '(api=$_apiRefCount, sendspin=$_sendspinRefCount)',
      );
      await _createAndConnectManager();
      _reconnectAttempts = 0;
      _logger.log('WebRTC shared session [$remoteId]: connected');
      completer.complete();
    } catch (error, stackTrace) {
      _logger.log('WebRTC shared session [$remoteId]: connect failed: $error');
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      if (identical(_connectInProgress, completer)) {
        _connectInProgress = null;
      }
    }
  }

  Future<void> sendApiMessage(String message) async {
    await ensureConnected();
    final manager = _manager;
    if (manager == null) {
      throw StateError('WebRTC shared session is not available');
    }
    await manager.sendApiMessage(message);
  }

  Future<void> sendSendspinMessage(String message) async {
    await ensureConnected();
    final manager = _manager;
    if (manager == null) {
      throw StateError('WebRTC shared session is not available');
    }
    await manager.sendSendspinMessage(message);
  }

  Future<void> release(WebRtcSessionChannel channel) async {
    switch (channel) {
      case WebRtcSessionChannel.api:
        if (_apiRefCount > 0) {
          _apiRefCount--;
        }
        break;
      case WebRtcSessionChannel.sendspin:
        if (_sendspinRefCount > 0) {
          _sendspinRefCount--;
        }
        break;
    }

    _logger.log(
      'WebRTC shared session [$remoteId]: released ${channel.name} '
      '(api=$_apiRefCount, sendspin=$_sendspinRefCount)',
    );

    if (!hasListeners) {
      _manualShutdown = true;
      _logger.log('WebRTC shared session [$remoteId]: shutting down (last consumer released)');
      await _shutdown();
      await _apiMessagesController.close();
      await _sendspinMessagesController.close();
      _disposed = true;
      _onReleased();
    }
  }

  Future<void> _createAndConnectManager() async {
    await _detachManager();

    final manager = WebRtcConnectionManager(
      remoteId: remoteId,
      enableApiChannel: true,
      enableSendspinChannel: true,
    );
    _manager = manager;

    _apiSubscription = manager.messages.listen(
      (message) {
        if (!_apiMessagesController.isClosed) {
          _apiMessagesController.add(message);
        }
      },
      onError: (error, stackTrace) {
        if (!_apiMessagesController.isClosed) {
          _apiMessagesController.addError(error, stackTrace);
        }
      },
    );

    _sendspinSubscription = manager.sendspinMessages.listen(
      (message) {
        if (!_sendspinMessagesController.isClosed) {
          _sendspinMessagesController.add(message);
        }
      },
      onError: (error, stackTrace) {
        if (!_sendspinMessagesController.isClosed) {
          _sendspinMessagesController.addError(error, stackTrace);
        }
      },
    );

    _stateSubscription = manager.connectionState.listen((state) {
      _logger.log('WebRTC shared session [$remoteId]: manager state=${state.name}');
      if (_disposed || _manualShutdown || !hasListeners) {
        return;
      }

      if (state == WebRtcConnectionState.disconnected ||
          state == WebRtcConnectionState.error) {
        _scheduleReconnect();
      }
    });

    await manager.connect();
  }

  void _scheduleReconnect() {
    if (_manualShutdown || _disposed || !hasListeners) {
      return;
    }

    if (_connectInProgress != null && !_connectInProgress!.isCompleted) {
      return;
    }

    _reconnectTimer?.cancel();
    final cappedAttempt = _reconnectAttempts > 4 ? 4 : _reconnectAttempts;
    final delaySeconds = 1 << cappedAttempt;
    _reconnectAttempts++;

    _logger.log(
      'WebRTC shared session [$remoteId]: scheduling reconnect '
      'attempt=$_reconnectAttempts delay=${delaySeconds}s',
    );

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_manualShutdown || _disposed || !hasListeners) {
        return;
      }

      _logger.log('WebRTC shared session [$remoteId]: reconnect timer fired');
      unawaited(ensureConnected());
    });
  }

  Future<void> _shutdown() async {
    _logger.log('WebRTC shared session [$remoteId]: shutdown requested');
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _detachManager();
  }

  Future<void> _detachManager() async {
    await _apiSubscription?.cancel();
    _apiSubscription = null;
    await _sendspinSubscription?.cancel();
    _sendspinSubscription = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;

    final manager = _manager;
    _manager = null;
    if (manager != null) {
      _logger.log('WebRTC shared session [$remoteId]: detaching active manager');
      await manager.disconnect();
      manager.dispose();
    }
  }
}

typedef VoidCallback = void Function();