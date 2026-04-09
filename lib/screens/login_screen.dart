import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/music_assistant_provider.dart';
import '../services/settings_service.dart';
import '../services/database_service.dart';
import '../services/profile_service.dart';
import '../services/debug_logger.dart';
import '../widgets/debug/debug_console.dart';
import '../l10n/app_localizations.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _remoteIdController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _usernameFocusNode = FocusNode();
  final _logger = DebugLogger();

  bool _isConnecting = false;
  String? _error;
  bool _showDebug = false;
  bool _useWebRtc = false;

  @override
  void initState() {
    super.initState();
    _loadSavedConnectionSettings();
  }

  Future<void> _loadSavedConnectionSettings() async {
    final serverUrl = await SettingsService.getServerUrl();
    final username = await SettingsService.getUsername();
    final remoteId = await SettingsService.getWebRtcRemoteId();
    final mode = await SettingsService.getPreferredConnectionMode();
    final webRtcEnabled = await SettingsService.getWebRtcEnabled();

    if (!mounted) {
      return;
    }

    setState(() {
      if (serverUrl != null && serverUrl.isNotEmpty) {
        _serverUrlController.text = serverUrl;
      }
      if (username != null && username.isNotEmpty) {
        _usernameController.text = username;
      }
      if (remoteId != null && remoteId.isNotEmpty) {
        _remoteIdController.text = remoteId;
      }
      _useWebRtc = webRtcEnabled && mode == 'webrtc';
    });
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _remoteIdController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    super.dispose();
  }

  /// Normalize server URL and add default port for local IPs
  String _buildServerUrl(String input) {
    var url = input.trim();

    // Remove trailing slashes
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // Add protocol if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (_isLocalAddress(url)) {
        url = 'http://$url';
      } else if (url.endsWith('.ts.net') || url.contains('.ts.net:')) {
        // Tailscale - use http since VPN is encrypted
        url = 'http://$url';
      } else {
        url = 'https://$url';
      }
    }

    // Add default port 8095 for local IPs without a port
    final uri = Uri.parse(url);
    if (!uri.hasPort && _isLocalAddress(uri.host)) {
      return '${uri.scheme}://${uri.host}:8095';
    }

    return url;
  }

  /// Check if address is local/private
  bool _isLocalAddress(String host) {
    return host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.16.') ||
        host.startsWith('172.17.') ||
        host.startsWith('172.18.') ||
        host.startsWith('172.19.') ||
        host.startsWith('172.2') ||
        host.startsWith('172.30.') ||
        host.startsWith('172.31.') ||
        host == 'localhost' ||
        host.startsWith('127.');
  }

  Future<void> _connect() async {
    final serverInput = _serverUrlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    // Validate inputs
    if (!_useWebRtc && serverInput.isEmpty) {
      setState(() => _error = S.of(context)!.pleaseEnterServerAddress);
      return;
    }
    if (username.isEmpty) {
      setState(() => _error = S.of(context)!.pleaseEnterCredentials);
      _usernameFocusNode.requestFocus();
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = S.of(context)!.pleaseEnterCredentials);
      return;
    }
    if (_useWebRtc && _remoteIdController.text.trim().isEmpty) {
      setState(() => _error = S.of(context)!.pleaseEnterRemoteId);
      return;
    }

    setState(() {
      _isConnecting = true;
      _error = null;
    });

    try {
      final serverUrl = serverInput.isEmpty ? null : _buildServerUrl(serverInput);
      _logger.log(
        'Connecting using ${_useWebRtc ? 'WebRTC' : 'direct'} mode'
        '${serverUrl != null ? ' to: $serverUrl' : ''}',
      );

      final provider = context.read<MusicAssistantProvider>();

      await provider.setWebRtcEnabled(_useWebRtc);
      await provider.setPreferredConnectionMode(_useWebRtc ? 'webrtc' : 'direct');
      await provider.setWebRtcRemoteId(_remoteIdController.text.trim());

      // Connect to server
      await provider.connectToServer(serverUrl);

      // Authenticate with MA
      _logger.log('Authenticating with Music Assistant...');

      // Check if we have a stored MA token first
      final storedToken = await SettingsService.getMaAuthToken();
      bool authSuccess = false;

      if (storedToken != null && provider.api != null) {
        _logger.log('Trying stored MA token...');
        authSuccess = await provider.api!.authenticateWithToken(storedToken);
      }

      if (!authSuccess) {
        _logger.log('Logging in with credentials...');
        final accessToken = await provider.api?.loginWithCredentials(username, password);

        if (accessToken == null) {
          setState(() {
            _error = S.of(context)!.maLoginFailed;
            _isConnecting = false;
          });
          return;
        }

        // Try to create a long-lived token for future use
        final longLivedToken = await provider.api?.createLongLivedToken();
        final tokenToStore = longLivedToken ?? accessToken;

        // Save the token for future auto-login
        await SettingsService.setMaAuthToken(tokenToStore);
        _logger.log('MA token saved for future logins');
      }

      // Save credentials
      await SettingsService.setUsername(username);
      await SettingsService.setPassword(password);
      if (serverUrl != null) {
        await SettingsService.setServerUrl(serverUrl);
      }

      // Save auth credentials to settings
      await SettingsService.setAuthCredentials({
        'strategy': 'music_assistant',
        'data': {'username': username},
      });

      // Set owner name from username for profile
      if (DatabaseService.instance.isInitialized) {
        await ProfileService.instance.onManualNameEntered(username);
      }

      // Wait for connection to complete
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (provider.isConnected) break;
      }

      if (provider.isConnected) {
        // First-time user: wait for player selection
        final hasCompletedOnboarding = await SettingsService.getHasCompletedOnboarding();
        if (!hasCompletedOnboarding) {
          for (int i = 0; i < 20; i++) {
            await Future.delayed(const Duration(milliseconds: 250));
            if (provider.selectedPlayer != null) break;
          }
        }

        // Navigate to home screen
        if (mounted) {
          FocusScope.of(context).unfocus();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const HomeScreen()),
          );
        }
      } else {
        setState(() {
          _error = S.of(context)!.connectionFailed;
          _isConnecting = false;
        });
      }
    } catch (e) {
      _logger.log('Connection error: $e');
      setState(() {
        _error = 'Connection failed: ${e.toString()}';
        _isConnecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: colorScheme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 78.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 60),

              // Logo
              Builder(
                builder: (context) {
                  final width = MediaQuery.of(context).size.width * 0.5;
                  return Center(
                    child: Image.asset(
                      'assets/images/ensemble_icon_transparent.png',
                      width: width,
                      fit: BoxFit.contain,
                    ),
                  );
                },
              ),

              const SizedBox(height: 48),

              if (!_useWebRtc) ...[
                Text(
                  S.of(context)!.serverAddress,
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.onBackground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: _serverUrlController,
                  style: TextStyle(color: colorScheme.onSurface),
                  decoration: InputDecoration(
                    hintText: S.of(context)!.serverAddressHint,
                    hintStyle: TextStyle(color: colorScheme.onSurface.withOpacity(0.38)),
                    filled: true,
                    fillColor: colorScheme.surfaceVariant.withOpacity(0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: Icon(
                      Icons.dns_rounded,
                      color: colorScheme.onSurface.withOpacity(0.54),
                    ),
                  ),
                  enabled: !_isConnecting,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                ),

                const SizedBox(height: 24),
              ],

              Row(
                children: [
                  Expanded(
                    child: Text(
                      S.of(context)!.connectionMethod,
                      style: textTheme.titleMedium?.copyWith(
                        color: colorScheme.onBackground,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text(S.of(context)!.directConnection),
                        icon: const Icon(Icons.dns_rounded),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text(S.of(context)!.webRtcConnection),
                        icon: const Icon(Icons.hub_rounded),
                      ),
                    ],
                    selected: {_useWebRtc},
                    onSelectionChanged: _isConnecting
                        ? null
                        : (selection) {
                            setState(() {
                              _useWebRtc = selection.first;
                            });
                          },
                  ),
                ],
              ),

              if (_useWebRtc) ...[
                const SizedBox(height: 24),
                Text(
                  S.of(context)!.remoteId,
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.onBackground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _remoteIdController,
                  style: TextStyle(color: colorScheme.onSurface),
                  decoration: InputDecoration(
                    hintText: S.of(context)!.remoteIdHint,
                    hintStyle: TextStyle(color: colorScheme.onSurface.withOpacity(0.38)),
                    filled: true,
                    fillColor: colorScheme.surfaceVariant.withOpacity(0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: Icon(
                      Icons.password_rounded,
                      color: colorScheme.onSurface.withOpacity(0.54),
                    ),
                  ),
                  enabled: !_isConnecting,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 24),
              ],

              // Username
              Text(
                S.of(context)!.username,
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onBackground,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: _usernameController,
                focusNode: _usernameFocusNode,
                style: TextStyle(color: colorScheme.onSurface),
                decoration: InputDecoration(
                  hintText: S.of(context)!.username,
                  hintStyle: TextStyle(color: colorScheme.onSurface.withOpacity(0.38)),
                  filled: true,
                  fillColor: colorScheme.surfaceVariant.withOpacity(0.3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: Icon(
                    Icons.person_rounded,
                    color: colorScheme.onSurface.withOpacity(0.54),
                  ),
                ),
                enabled: !_isConnecting,
                textInputAction: TextInputAction.next,
              ),

              const SizedBox(height: 24),

              // Password
              Text(
                S.of(context)!.password,
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onBackground,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: _passwordController,
                style: TextStyle(color: colorScheme.onSurface),
                decoration: InputDecoration(
                  hintText: S.of(context)!.password,
                  hintStyle: TextStyle(color: colorScheme.onSurface.withOpacity(0.38)),
                  filled: true,
                  fillColor: colorScheme.surfaceVariant.withOpacity(0.3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: Icon(
                    Icons.lock_rounded,
                    color: colorScheme.onSurface.withOpacity(0.54),
                  ),
                ),
                obscureText: true,
                enabled: !_isConnecting,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connect(),
              ),

              const SizedBox(height: 32),

              // Error message
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colorScheme.error.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_rounded, color: colorScheme.error, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.onErrorContainer, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),

              // Debug toggle button
              DebugToggleButton(
                isVisible: _showDebug,
                onToggle: () => setState(() => _showDebug = !_showDebug),
              ),

              // Debug panel
              if (_showDebug) ...[
                const SizedBox(height: 16),
                DebugConsole(
                  onClear: () {},
                ),
                const SizedBox(height: 16),
              ],

              // Connect button
              ElevatedButton(
                onPressed: _isConnecting ? null : _connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isConnecting
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(colorScheme.onPrimary),
                        ),
                      )
                    : Text(
                        S.of(context)!.connect,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
