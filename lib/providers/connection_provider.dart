import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/music_assistant_api.dart';
import '../services/remote/webrtc_api_transport.dart';
import '../services/settings_service.dart';
import '../services/debug_logger.dart';
import '../services/error_handler.dart';
import '../services/auth/auth_manager.dart';

/// Called right after the [MusicAssistantAPI] instance is (re)created,
/// before [connect()] is invoked. Use this to subscribe to API event streams.
typedef OnApiCreated = void Function(MusicAssistantAPI api);

/// Called once the server is ready for initialization
/// (connected without auth, or authentication succeeded).
typedef OnReadyForInit = Future<void> Function();

/// Provider for connection state management.
///
/// Handles:
/// - WebSocket connection lifecycle
/// - Authentication flow (token, credentials, long-lived tokens)
/// - User settings capture (provider/player filters, profile name)
///
/// Integrated into [MusicAssistantProvider] via composition:
/// MAP holds a [ConnectionProvider], wires its callbacks and exposes
/// delegating getters so all existing consumers remain unchanged.
class ConnectionProvider with ChangeNotifier {
  static const String _webRtcBootstrapServerUrl =
      'https://remote.music-assistant.invalid';

  final DebugLogger _logger = DebugLogger();
  final AuthManager _authManager = AuthManager();

  MusicAssistantAPI? _api;
  String? _serverUrl;
  String? _error;
  MAConnectionState _connectionState = MAConnectionState.disconnected;
  String _preferredConnectionMode = 'direct';
  bool _webRtcEnabled = false;
  String? _webRtcRemoteId;

  StreamSubscription? _connectionStateSubscription;

  // ─── Callbacks wired by MusicAssistantProvider ──────────────────────────────

  /// Called right after the API instance is (re)created.
  /// MAP uses this to resubscribe to playerUpdated / mediaItemAdded events.
  OnApiCreated? onApiCreated;

  /// Called when the connection is ready for initialization.
  /// Replaces the old onConnected + onAuthenticated pair.
  OnReadyForInit? onReadyForInit;

  // User settings captured during authentication
  List<String> _providerFilter = [];
  List<String> _playerFilter = [];

  // ============================================================================
  // GETTERS
  // ============================================================================

  MusicAssistantAPI? get api => _api;
  AuthManager get authManager => _authManager;
  String? get serverUrl => _serverUrl;
  String? get error => _error;
  MAConnectionState get connectionState => _connectionState;
  String get preferredConnectionMode => _preferredConnectionMode;
  bool get webRtcEnabled => _webRtcEnabled;
  String? get webRtcRemoteId => _webRtcRemoteId;
  bool get hasDirectConnectionProfile =>
      _serverUrl != null && _serverUrl!.isNotEmpty;
  bool get hasWebRtcConnectionProfile =>
      _webRtcEnabled && _webRtcRemoteId != null && _webRtcRemoteId!.isNotEmpty;
  bool get hasActiveConnectionProfile =>
      _preferredConnectionMode == 'webrtc'
          ? hasWebRtcConnectionProfile
          : hasDirectConnectionProfile;

  bool get isConnected =>
      _connectionState == MAConnectionState.connected ||
      _connectionState == MAConnectionState.authenticated;

  List<String> get providerFilter => _providerFilter;
  List<String> get playerFilter => _playerFilter;

  // ============================================================================
  // AUTH HELPERS
  // ============================================================================

  Future<void> loadConnectionPreferences() async {
    _serverUrl = await SettingsService.getServerUrl();
    _preferredConnectionMode = await SettingsService.getPreferredConnectionMode();
    _webRtcEnabled = await SettingsService.getWebRtcEnabled();
    _webRtcRemoteId = await SettingsService.getWebRtcRemoteId();
    notifyListeners();
  }

  Future<void> setPreferredConnectionMode(String mode) async {
    _preferredConnectionMode = mode;
    await SettingsService.setPreferredConnectionMode(mode);
    notifyListeners();
  }

  Future<void> setWebRtcEnabled(bool enabled) async {
    _webRtcEnabled = enabled;
    await SettingsService.setWebRtcEnabled(enabled);
    notifyListeners();
  }

  Future<void> setWebRtcRemoteId(String? remoteId) async {
    _webRtcRemoteId = _normalizeWebRtcRemoteId(remoteId);
    await SettingsService.setWebRtcRemoteId(_webRtcRemoteId);
    notifyListeners();
  }

  String? _normalizeWebRtcRemoteId(String? remoteId) {
    final normalized = remoteId
        ?.replaceAll('-', '')
        .replaceAll(' ', '')
        .trim()
        .toUpperCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  /// Pre-load a stored token into the auth manager before the first [connect()].
  Future<void> restoreAuth() async {
    final storedToken = await SettingsService.getMaAuthToken();
    if (storedToken != null) {
      _logger.log('🔐 Restoring saved MA token...');
      _authManager.setToken(storedToken);
      _logger.log('🔐 Auth token restored');
    }
  }

  /// Fetch and store user settings (profile name, provider/player filters).
  /// Called automatically after successful authentication; MAP can also call
  /// this directly from _initializeAfterConnection when authRequired is set.
  Future<void> fetchUserSettings() async {
    if (_api == null) return;

    try {
      final userInfo = await _api!.getCurrentUserInfo();
      if (userInfo == null) return;

      // Set profile name
      final displayName = userInfo['display_name'] as String?;
      final username = userInfo['username'] as String?;
      final profileName =
          (displayName != null && displayName.isNotEmpty) ? displayName : username;

      if (profileName != null && profileName.isNotEmpty) {
        await SettingsService.setOwnerName(profileName);
        _logger.log('✅ Set owner name from MA profile: $profileName');
      }

      // Capture provider filter (empty = all providers allowed)
      final providerFilterRaw = userInfo['provider_filter'];
      if (providerFilterRaw is List) {
        _providerFilter = providerFilterRaw.cast<String>().toList();
        if (_providerFilter.isNotEmpty) {
          _logger.log('🔒 Provider filter active: ${_providerFilter.length} providers allowed');
          _logger.log('   Allowed: ${_providerFilter.join(", ")}');
        } else {
          _logger.log('🔓 No provider filter - all providers visible');
        }
      } else {
        _providerFilter = [];
        _logger.log('🔓 No provider filter in user settings');
      }

      // Capture player filter (empty = all players allowed)
      final playerFilterRaw = userInfo['player_filter'];
      if (playerFilterRaw is List) {
        _playerFilter = playerFilterRaw.cast<String>().toList();
        if (_playerFilter.isNotEmpty) {
          _logger.log('🔒 Player filter active: ${_playerFilter.length} players allowed');
          _logger.log('   Allowed: ${_playerFilter.join(", ")}');
        } else {
          _logger.log('🔓 No player filter - all players visible');
        }
      } else {
        _playerFilter = [];
        _logger.log('🔓 No player filter in user settings');
      }
    } catch (e) {
      _logger.log('⚠️ Could not fetch user settings (non-fatal): $e');
    }
  }

  // ============================================================================
  // CONNECTION
  // ============================================================================

  /// Connect to the Music Assistant server.
  Future<void> connect(String? serverUrl) async {
    try {
      _error = null;

      final wantsWebRtc =
          _webRtcEnabled &&
          _preferredConnectionMode == 'webrtc' &&
          _webRtcRemoteId != null &&
          _webRtcRemoteId!.isNotEmpty;

      final normalizedServerUrl = serverUrl?.trim();
      final hasExplicitServerUrl =
          normalizedServerUrl != null && normalizedServerUrl.isNotEmpty;

      if (!wantsWebRtc && !hasExplicitServerUrl) {
        throw ArgumentError('serverUrl is required for direct connection mode');
      }

      if (hasExplicitServerUrl) {
        _serverUrl = normalizedServerUrl;
        await SettingsService.setServerUrl(normalizedServerUrl!);
      } else {
        _serverUrl ??= await SettingsService.getServerUrl();
      }

      final effectiveServerUrl = hasExplicitServerUrl
          ? normalizedServerUrl!
          : (_serverUrl?.isNotEmpty == true
              ? _serverUrl!
              : _webRtcBootstrapServerUrl);

      _serverUrl = effectiveServerUrl;

      // Dispose old API to stop pending reconnects
      _api?.dispose();

      _api = MusicAssistantAPI(
        effectiveServerUrl,
        _authManager,
        transportBuilder: wantsWebRtc
            ? (_) => WebRtcApiTransport(remoteId: _webRtcRemoteId!)
            : null,
      );

      // Notify MAP so it can resubscribe to API event streams
      onApiCreated?.call(_api!);

      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = _api!.connectionState.listen(
        (state) async {
          if (state == MAConnectionState.connected) {
            _logger.log('🔗 Connection established to MA server');

            if (_api!.authRequired && !_api!.isAuthenticated) {
              // Don't broadcast 'connected' yet — AppStartup watches isConnected
              // and would navigate to HomeScreen before auth completes, causing
              // all data fetches to fail with "Not authenticated".
              _logger.log('🔐 MA auth required, attempting authentication...');
              final authenticated = await _handleAuthentication();
              if (!authenticated) {
                _connectionState = MAConnectionState.error;
                _error = 'Authentication required. Please log in again.';
                notifyListeners();
              }
              // The 'authenticated' event fires next and is handled below
              return;
            }

            // No auth required — safe to broadcast and initialize
            _connectionState = state;
            notifyListeners();
            await onReadyForInit?.call();
          } else if (state == MAConnectionState.authenticated) {
            _connectionState = state;
            notifyListeners();
            _logger.log('✅ MA authentication successful');
            await onReadyForInit?.call();
          } else if (state == MAConnectionState.disconnected) {
            _connectionState = state;
            notifyListeners();
            // DON'T clear caches on disconnect — keep for instant resume
            _logger.log('📡 Disconnected - keeping cached data for instant resume');
          } else {
            _connectionState = state;
            notifyListeners();
          }
        },
        onError: (error) {
          _logger.log('Connection state stream error: $error');
          _connectionState = MAConnectionState.error;
          notifyListeners();
        },
      );

      await _api!.connect();
      notifyListeners();
    } catch (e) {
      final errorInfo = ErrorHandler.handleError(e, context: 'Connect to server');
      _error = errorInfo.userMessage;
      _connectionState = MAConnectionState.error;
      _logger.log('Connection error: ${errorInfo.technicalMessage}');
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> _handleAuthentication() async {
    if (_api == null) return false;

    try {
      final storedToken = await SettingsService.getMaAuthToken();
      if (storedToken != null) {
        _logger.log('🔐 Trying stored MA token...');
        final success = await _api!.authenticateWithToken(storedToken);
        if (success) {
          _logger.log('✅ MA authentication with stored token successful');
          await fetchUserSettings();
          return true;
        }
        _logger.log('⚠️ Stored MA token invalid, clearing...');
        await SettingsService.clearMaAuthToken();
      }

      final username = await SettingsService.getUsername();
      final password = await SettingsService.getPassword();

      if (username != null &&
          password != null &&
          username.isNotEmpty &&
          password.isNotEmpty) {
        _logger.log('🔐 Trying stored credentials...');
        final accessToken = await _api!.loginWithCredentials(username, password);

        if (accessToken != null) {
          _logger.log('✅ MA login with stored credentials successful');

          final longLivedToken = await _api!.createLongLivedToken();
          if (longLivedToken != null) {
            await SettingsService.setMaAuthToken(longLivedToken);
            _logger.log('✅ Saved new long-lived MA token');
          } else {
            await SettingsService.setMaAuthToken(accessToken);
          }

          await fetchUserSettings();
          return true;
        }
      }

      _logger.log('❌ MA authentication failed - no valid token or credentials');
      return false;
    } catch (e) {
      _logger.log('❌ MA authentication error: $e');
      return false;
    }
  }

  /// Disconnect the WebSocket only.
  /// Call this from MAP's disconnect() after tearing down Sendspin/PCM.
  Future<void> disconnect() async {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _api?.disconnect();
    _connectionState = MAConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionStateSubscription?.cancel();
    _api?.dispose();
    super.dispose();
  }
}
