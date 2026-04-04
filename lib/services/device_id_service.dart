import 'dart:io';
import 'dart:ui' as ui;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'debug_logger.dart';
import 'settings_service.dart';

/// Service to generate unique per-device player IDs
/// Uses stable device identifiers (ANDROID_ID) combined with MA username
/// to create persistent player IDs that survive storage wipes and support
/// multiple devices per account
class DeviceIdService {
  static const String _keyLocalPlayerId = 'local_player_id';
  static final _logger = DebugLogger();

  // Cache stable device ID to avoid repeated platform calls
  static String? _cachedStableDeviceId;

  /// Get stable device identifier that persists across storage wipes
  /// - Android: Uses ANDROID_ID (persists until factory reset)
  /// - iOS: Uses identifierForVendor (persists until app reinstall)
  static Future<String> _getStableDeviceId() async {
    if (_cachedStableDeviceId != null) {
      return _cachedStableDeviceId!;
    }

    final deviceInfo = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      // Use ANDROID_ID (android.androidId) for a stable per-device identifier.
      // android.id is Build.ID and may change across OTA updates.
      final androidId = android.androidId;
      _cachedStableDeviceId =
          (androidId != null && androidId.isNotEmpty) ? androidId : android.id;
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      // identifierForVendor persists across app updates but resets on reinstall
      _cachedStableDeviceId = ios.identifierForVendor ?? 'unknown_ios';
    } else {
      // Fallback for other platforms (web, desktop)
      _cachedStableDeviceId = 'unknown_platform';
    }

    return _cachedStableDeviceId!;
  }

  /// Detect if device is a tablet based on screen size
  /// Uses the standard 600dp threshold (shortest side >= 600 = tablet)
  static bool get isTablet {
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      return size.shortestSide >= 600;
    } catch (e) {
      _logger.log('Failed to detect device type: $e');
      return false; // Default to phone if detection fails
    }
  }

  /// Get or generate a unique player ID for this device
  /// Format: ensemble_{username}_{deviceId} or ensemble_{deviceId}
  ///
  /// Key behaviors:
  /// - Uses stable device ID that survives storage wipes
  /// - Includes MA username to support multiple devices per account
  /// - Regenerates if username changes (user logged in with different account)
  static Future<String> getOrCreateDevicePlayerId() async {
    final prefs = await SharedPreferences.getInstance();
    final stableDeviceId = await _getStableDeviceId();
    final maUsername = await SettingsService.getUsername();

    // Generate expected ID based on current username and device
    // Use shorter device ID suffix (first 8 chars) to keep ID reasonable length
    final deviceIdSuffix = stableDeviceId.length > 8
        ? stableDeviceId.substring(0, 8)
        : stableDeviceId;

    final expectedId = maUsername != null && maUsername.isNotEmpty
        ? 'ensemble_${maUsername}_$deviceIdSuffix'
        : 'ensemble_$deviceIdSuffix';

    // Check if we already have the correct ID
    final existingId = prefs.getString(_keyLocalPlayerId);
    if (existingId == expectedId) {
      _logger.log('Using existing player ID: $expectedId');
      return expectedId;
    }

    // ID needs to be updated (first login, username changed, or migration)
    if (existingId != null) {
      _logger.log('Updating player ID from $existingId to $expectedId');
    } else {
      _logger.log('Generated new player ID: $expectedId');
    }

    await prefs.setString(_keyLocalPlayerId, expectedId);
    return expectedId;
  }

  /// Adopt an existing player ID (used when claiming a ghost player)
  static Future<void> adoptPlayerId(String playerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLocalPlayerId, playerId);
    _logger.log('Adopted player ID: $playerId');
  }

  /// Check if this is a fresh installation (no player ID stored yet)
  static Future<bool> isFreshInstallation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLocalPlayerId) == null;
  }

  /// Force regeneration of player ID on next call
  /// Useful after login/logout to ensure ID matches current user
  static Future<void> invalidateCachedId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLocalPlayerId);
    _logger.log('Invalidated cached player ID');
  }
}
