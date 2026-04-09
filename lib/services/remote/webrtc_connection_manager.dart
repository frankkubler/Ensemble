import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_client.dart';

enum WebRtcConnectionState {
  idle,
  connecting,
  negotiating,
  connected,
  disconnected,
  error,
}

class WebRtcConnectionManager {
  WebRtcConnectionManager({
    required this.remoteId,
    this.enableApiChannel = true,
    this.enableSendspinChannel = false,
    SignalingClient? signalingClient,
  }) : _signalingClient = signalingClient ?? SignalingClient();

  final String remoteId;
  final bool enableApiChannel;
  final bool enableSendspinChannel;
  final SignalingClient _signalingClient;

  final _stateController = StreamController<WebRtcConnectionState>.broadcast();
  final _messageController = StreamController<dynamic>.broadcast();
  final _sendspinMessageController = StreamController<dynamic>.broadcast();

  StreamSubscription<Map<String, dynamic>>? _signalingSubscription;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _apiChannel;
  RTCDataChannel? _sendspinChannel;
  Completer<void>? _connectCompleter;
  String? _sessionId;
  bool _disposed = false;
  WebRtcConnectionState _state = WebRtcConnectionState.idle;
  final Set<String> _openChannels = <String>{};

  Stream<WebRtcConnectionState> get connectionState => _stateController.stream;
  Stream<dynamic> get messages => _messageController.stream;
  Stream<dynamic> get sendspinMessages => _sendspinMessageController.stream;
  WebRtcConnectionState get currentState => _state;
  bool get isConnected => _state == WebRtcConnectionState.connected;

  Future<void> connect() async {
    if (_disposed) {
      throw StateError('WebRTC manager is disposed');
    }
    if (_state == WebRtcConnectionState.connecting ||
        _state == WebRtcConnectionState.negotiating ||
        _state == WebRtcConnectionState.connected) {
      return;
    }

    _setState(WebRtcConnectionState.connecting);
    _connectCompleter = Completer<void>();

    await _signalingClient.connect();
    await _signalingSubscription?.cancel();
    _signalingSubscription =
        _signalingClient.messages.listen(_handleSignalingMessage);
    await _signalingClient.sendConnectRequest(remoteId);

    await _connectCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('WebRTC connection timed out'),
    );
  }

  Future<void> sendApiMessage(String message) async {
    final channel = _apiChannel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('WebRTC API channel is not open');
    }

    channel.send(RTCDataChannelMessage(message));
  }

  Future<void> sendSendspinMessage(String message) async {
    final channel = _sendspinChannel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('WebRTC Sendspin channel is not open');
    }

    channel.send(RTCDataChannelMessage(message));
  }

  Future<void> disconnect() async {
    await _signalingSubscription?.cancel();
    _signalingSubscription = null;

    await _apiChannel?.close();
    _apiChannel = null;

    await _sendspinChannel?.close();
    _sendspinChannel = null;

    await _peerConnection?.close();
    _peerConnection = null;

    _openChannels.clear();

    await _signalingClient.disconnect();
    if (!_disposed) {
      _setState(WebRtcConnectionState.disconnected);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;
    _stateController.close();
    _messageController.close();
    _sendspinMessageController.close();
    _signalingClient.dispose();
  }

  Future<void> _handleConnectedMessage(Map<String, dynamic> message) async {
    _setState(WebRtcConnectionState.negotiating);

    _sessionId = (message['sessionId'] ?? message['session_id']) as String?;
    final iceServers =
        _parseIceServers(message['iceServers'] ?? message['ice_servers']);

    _peerConnection = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });

    _peerConnection!.onIceCandidate = (candidate) {
      final sessionId = _sessionId;
      if (sessionId == null || candidate.candidate == null) {
        return;
      }

      unawaited(
        _signalingClient.sendMessage({
          'type': 'ice-candidate',
          'sessionId': sessionId,
          'data': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }),
      );
    };

    _peerConnection!.onDataChannel = (channel) {
      final label = channel.label;
      if ((label == 'ma-api' || (label?.isEmpty ?? false)) && enableApiChannel) {
        _bindApiChannel(channel);
      } else if (label == 'sendspin' && enableSendspinChannel) {
        _bindSendspinChannel(channel);
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _setState(WebRtcConnectionState.disconnected);
      }
    };

    if (enableApiChannel) {
      final apiChannel = await _peerConnection!.createDataChannel(
        'ma-api',
        RTCDataChannelInit()..ordered = true,
      );
      _bindApiChannel(apiChannel);
    }

    if (enableSendspinChannel) {
      final sendspinChannel = await _peerConnection!.createDataChannel(
        'sendspin',
        RTCDataChannelInit()..ordered = true,
      );
      _bindSendspinChannel(sendspinChannel);
    }

    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await _peerConnection!.setLocalDescription(offer);

    await _signalingClient.sendMessage({
      'type': 'offer',
      'sessionId': _sessionId,
      'data': {
        'type': offer.type,
        'sdp': offer.sdp,
      },
    });
  }

  Future<void> _handleSignalingMessage(Map<String, dynamic> message) async {
    final type = message['type'] as String?;
    if (type == null) {
      return;
    }

    switch (type) {
      case 'connected':
      case 'session-ready':
        await _handleConnectedMessage(message);
        break;
      case 'answer':
        final data = message['data'] as Map<String, dynamic>?;
        final sdp = data?['sdp'] as String?;
        final answerType = (data?['type'] as String?) ?? 'answer';
        if (_peerConnection != null && sdp != null) {
          await _peerConnection!.setRemoteDescription(
            RTCSessionDescription(sdp, answerType),
          );
        }
        break;
      case 'ice-candidate':
        final data = message['data'] as Map<String, dynamic>?;
        final candidate = data?['candidate'] as String?;
        if (_peerConnection != null && candidate != null) {
          await _peerConnection!.addCandidate(
            RTCIceCandidate(
              candidate,
              data?['sdpMid'] as String?,
              data?['sdpMLineIndex'] as int?,
            ),
          );
        }
        break;
      case 'error':
      case 'client-disconnected':
      case 'peer-disconnected':
        _setState(WebRtcConnectionState.error);
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.completeError(
            Exception(message['error'] ?? 'WebRTC signaling error'),
          );
        }
        break;
    }
  }

  void _bindApiChannel(RTCDataChannel channel) {
    _apiChannel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _markChannelOpen('ma-api');
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _markChannelClosed('ma-api');
      }
    };

    channel.onMessage = (message) {
      if (_messageController.isClosed) {
        return;
      }

      if (message.isBinary) {
        _messageController.add(utf8.decode(message.binary));
      } else {
        _messageController.add(message.text);
      }
    };
  }

  void _bindSendspinChannel(RTCDataChannel channel) {
    _sendspinChannel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _markChannelOpen('sendspin');
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _markChannelClosed('sendspin');
      }
    };

    channel.onMessage = (message) {
      if (_sendspinMessageController.isClosed) {
        return;
      }

      if (message.isBinary) {
        _sendspinMessageController.add(message.binary);
      } else {
        _sendspinMessageController.add(message.text);
      }
    };
  }

  void _markChannelOpen(String label) {
    _openChannels.add(label);
    if (_requiredChannels.every(_openChannels.contains)) {
      _setState(WebRtcConnectionState.connected);
      if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
        _connectCompleter!.complete();
      }
    }
  }

  void _markChannelClosed(String label) {
    _openChannels.remove(label);
    _setState(WebRtcConnectionState.disconnected);
  }

  Set<String> get _requiredChannels {
    final requiredChannels = <String>{};
    if (enableApiChannel) {
      requiredChannels.add('ma-api');
    }
    if (enableSendspinChannel) {
      requiredChannels.add('sendspin');
    }
    return requiredChannels;
  }

  List<Map<String, dynamic>> _parseIceServers(dynamic rawIceServers) {
    if (rawIceServers is! List) {
      return const [
        {'urls': 'stun:stun.home-assistant.io:3478'},
        {'urls': 'stun:stun.l.google.com:19302'},
      ];
    }

    return rawIceServers.map<Map<String, dynamic>>((server) {
      if (server is Map<String, dynamic>) {
        return {
          'urls': server['urls'],
          if (server['username'] != null) 'username': server['username'],
          if (server['credential'] != null) 'credential': server['credential'],
          if (server['password'] != null) 'credential': server['password'],
        };
      }

      return {'urls': server};
    }).toList();
  }

  void _setState(WebRtcConnectionState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}