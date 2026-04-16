import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../debug_logger.dart';
import '../auth/auth_manager.dart';
import '../settings_service.dart';
import '../sync_service.dart';
import '../../providers/music_assistant_provider.dart';
import '../../models/media_item.dart' as ma;
import '../../models/player.dart';
import 'android_auto_browsing_delegate.dart';

/// Custom AudioHandler for Ensemble that provides full control over
/// notification actions and metadata updates.
class MassivAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final AuthManager authManager;
  final _logger = DebugLogger();

  // Stream subscriptions for proper cleanup
  StreamSubscription? _interruptionSubscription;
  StreamSubscription? _becomingNoisySubscription;
  StreamSubscription? _playbackEventSubscription;
  StreamSubscription? _currentIndexSubscription;

  // Track current metadata separately from what's in the notification
  // This allows us to update the notification when metadata arrives late
  MediaItem? _currentMediaItem;

  // Callbacks for actions (wired up by MusicAssistantProvider)
  Function()? onSkipToNext;
  Function()? onSkipToPrevious;
  Function()? onPlay;
  Function()? onPause;
  Function()? onSwitchPlayer;
  Function()? onBrowseActivity;
  Function()? onAAConnected;
  Function()? onAADisconnected;

  // Track whether we're in remote control mode (controlling MA player, not playing locally)
  bool _isRemoteMode = false;

  // Android Auto: provider reference (set after app initialises)
  MusicAssistantProvider? _autoProvider;

  // Android Auto: browsing delegate — handles all category and item building.
  // The track cache is owned here so playFromMediaId can access it directly.
  static const _maxTrackCacheEntries = 50;
  static const _maxChildSubjectEntries = 100;
  final Map<String, List<ma.Track>> _autoTrackCache = {};
  late final AndroidAutoBrowsingDelegate _browsing = AndroidAutoBrowsingDelegate(
    logger: _logger,
    trackCache: _autoTrackCache,
  );

  void _cacheTrackList(String key, List<ma.Track> tracks) =>
      _browsing.cacheTrackList(key, tracks);

  // Android Auto: subjects for subscribeToChildren
  final Map<String, BehaviorSubject<Map<String, dynamic>>> _autoChildrenSubjects = {};

  // Android Auto connection state — used to hide switch player button from controls
  bool _isAndroidAutoConnected = false;

  /// Whether Android Auto is currently connected (public read-only).
  bool get isAndroidAutoConnected => _isAndroidAutoConnected;

  // Suppress auto-resume after audio route changes (e.g. BT/AA disconnect)
  bool _suppressResume = false;

  // Track whether music was actually playing before an interruption
  bool _wasPlayingBeforeInterruption = false;

  // Cancellable timer for deferred queue refresh after radio/podcast start
  Timer? _queueRefreshTimer;

  // Timestamp of last AA disconnect — used to suppress stream/start race condition
  DateTime? aaDisconnectedAt;

  // Android Auto method channel (Dart ↔ Native)
  static const _aaChannel = MethodChannel('com.collotsspot.ensemble/android_auto');
  bool _aaNativeChannelAvailable = true;
  bool _loggedAANativeChannelMissing = false;

  // Custom control for switching players
  static final _switchPlayerControl = MediaControl.custom(
    androidIcon: 'drawable/ic_switch_player',
    label: 'Switch Player',
    name: 'switchPlayer',
  );

  MassivAudioHandler({required this.authManager}) {
    _init();
  }

  Future<void> _notifyAAConnectedNative() async {
    if (!_aaNativeChannelAvailable) return;

    try {
      await _aaChannel.invokeMethod('notifyAAConnected');
    } on MissingPluginException {
      _aaNativeChannelAvailable = false;
      if (_loggedAANativeChannelMissing) return;
      _loggedAANativeChannelMissing = true;
      _logger.log(
        'AndroidAuto: native channel unavailable in this Flutter engine, skipping notifyAAConnected',
      );
    } catch (e) {
      _logger.log('AndroidAuto: notifyAAConnected failed: $e');
    }
  }

  Future<void> _init() async {
    // Configure audio session
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // Handle audio interruptions (e.g., another app takes audio focus)
    // Only act on interruptions when playing locally — remote MA players
    // manage their own audio focus on the server side.
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      _logger.log('🔊 Audio interruption: begin=${event.begin}, type=${event.type}, builtinActive=$_isBuiltinPlayerActive');
      if (!_isBuiltinPlayerActive) return;
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _player.setVolume(0.5);
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            _wasPlayingBeforeInterruption = playbackState.value.playing || _isBuiltinPlayerActive;
            if (_wasPlayingBeforeInterruption) {
              _player.pause();
              onPause?.call();
            }
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _player.setVolume(1.0);
            break;
          case AudioInterruptionType.pause:
            if (_suppressResume) {
              _logger.log('🔊 Audio interruption ended but resume suppressed (audio route changed)');
              _suppressResume = false;
              break;
            }
            if (!_wasPlayingBeforeInterruption) {
              _logger.log('🔊 Audio interruption ended but was not playing before');
              break;
            }
            _player.play();
            onPlay?.call();
            break;
          case AudioInterruptionType.unknown:
            break;
        }
      }
    });

    // Handle becoming noisy (headphones unplugged, BT/AA disconnected)
    _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
      _logger.log('🔊 Audio becoming noisy (route changed), suppressing resume');
      _suppressResume = true;
      pause();
    });

    // Broadcast playback state changes
    _playbackEventSubscription = _player.playbackEventStream.listen(_broadcastState);

    // Broadcast current media item changes (only for local just_audio playback)
    _currentIndexSubscription = _player.currentIndexStream.listen((_) {
      if (_isRemoteMode) return; // Don't resend metadata in remote/Sendspin mode
      if (_currentMediaItem != null) {
        _logger.log('🎵 currentIndexStream: re-adding mediaItem');
        mediaItem.add(_currentMediaItem);
      }
    });

    // Listen for Android Auto connection events from native side
    _aaChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAndroidAutoConnected':
          if (_isAndroidAutoConnected) break; // already handled via getChildren/playFromMediaId
          _logger.log('AndroidAuto: car mode connected (broadcast)');
          _isAndroidAutoConnected = true;
          unawaited(_notifyAAConnectedNative());
          onAAConnected?.call();
          _refreshPlaybackState();
        case 'onAndroidAutoDisconnected':
          _logger.log('AndroidAuto: car mode disconnected (broadcast)');
          _isAndroidAutoConnected = false;
          _suppressResume = true;
          aaDisconnectedAt = DateTime.now();
          onAADisconnected?.call();
          _refreshPlaybackState();
      }
    });
  }

  /// Broadcast the current playback state to the system
  void _broadcastState(PlaybackEvent event) {
    // In remote mode, playback state is managed by setRemotePlaybackState.
    // When _currentMediaItem is set, notification is managed by the provider
    // via updateLocalModeNotification/setRemotePlaybackState — don't let the
    // idle just_audio player overwrite it (it would send processingState=idle
    // which deactivates the media session and causes artwork to flash).
    if (_isRemoteMode || _currentMediaItem != null) return;

    final playing = _player.playing;

    playbackState.add(playbackState.value.copyWith(
      // Only transport controls for notification — custom actions are AA-only
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      // System-level actions (for headphones, car stereos, etc.)
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      // Which buttons to show in compact notification (max 3)
      // Show: prev (0), play/pause (1), next (2)
      androidCompactActionIndices: const [0, 1, 2],
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
  }

  // --- Playback control methods ---

  @override
  Future<void> play() async {
    // Always prefer callbacks — they handle both remote players and
    // Sendspin PCM (which uses local mode but delegates playback to MA server)
    if (onPlay != null) {
      onPlay!.call();
    } else {
      await _player.play();
    }
  }

  @override
  Future<void> pause() async {
    if (onPause != null) {
      onPause!.call();
    } else {
      await _player.pause();
    }
  }

  @override
  Future<void> stop() async {
    if (onSwitchPlayer != null) {
      // Notification button repurposed for player switching
      onSwitchPlayer!.call();
    } else {
      // Genuine system stop (phone call, BT command, etc.) — fully stop service
      await stopService();
    }
  }

  /// Fully stop the foreground service and release resources
  /// Called after idle timeout to save battery
  Future<void> stopService() async {
    _logger.log('MassivAudioHandler: Stopping foreground service (idle timeout)');
    _isRemoteMode = false;
    _currentMediaItem = null;
    await _player.stop();
    // Call the base stop() to properly stop the foreground service
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    onSkipToPrevious?.call();
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    _logger.log('AndroidAuto: customAction called: $name');
    final provider = _autoProvider;
    if (provider == null) {
      _logger.log('AndroidAuto: customAction: no provider');
      return;
    }
    // Look up fresh player state (selectedPlayer may have stale cached activeQueue)
    final selectedId = provider.selectedPlayer?.playerId;
    if (selectedId == null) {
      _logger.log('AndroidAuto: customAction: no selectedPlayer');
      return;
    }
    final player = provider.availablePlayersUnfiltered
        .where((p) => p.playerId == selectedId).firstOrNull ?? provider.selectedPlayer!;
    _logger.log('AndroidAuto: customAction: player=${player.name}, activeQueue=${player.activeQueue}');

    try {
      switch (name) {
        case 'toggleShuffle':
          final queue = await provider.getQueue(player.playerId);
          final newShuffle = !(queue?.shuffle ?? false);
          _logger.log('AndroidAuto: toggleShuffle: current=${queue?.shuffle}, setting=$newShuffle');
          await provider.toggleShuffle(player.playerId, newShuffle);
          _shuffleOn = newShuffle;
        case 'toggleFavorite':
          final track = provider.currentTrack;
          if (track == null) {
            _logger.log('AndroidAuto: toggleFavorite: no currentTrack');
            return;
          }
          _logger.log('AndroidAuto: toggleFavorite: track=${track.name}, favorite=${_isFavorite}, provider=${track.provider}');
          if (_isFavorite) {
            int? libraryItemId;
            if (track.provider == 'library') {
              libraryItemId = int.tryParse(track.itemId);
            } else if (track.providerMappings != null) {
              final libraryMapping = track.providerMappings!.firstWhere(
                (m) => m.providerInstance == 'library',
                orElse: () => track.providerMappings!.first,
              );
              if (libraryMapping.providerInstance == 'library') {
                libraryItemId = int.tryParse(libraryMapping.itemId);
              }
            }
            _logger.log('AndroidAuto: toggleFavorite: removing, libraryItemId=$libraryItemId');
            if (libraryItemId == null) {
              _logger.log('AndroidAuto: toggleFavorite: no library mapping, cannot remove');
              return;
            }
            await provider.removeFromFavorites(
              mediaType: 'track', libraryItemId: libraryItemId);
            _isFavorite = false;
          } else {
            _logger.log('AndroidAuto: toggleFavorite: adding');
            await provider.addToFavorites(
              mediaType: 'track', itemId: track.itemId, provider: track.provider);
            _isFavorite = true;
          }
        case 'startRadio':
          final track = provider.currentTrack;
          if (track == null) {
            _logger.log('AndroidAuto: startRadio: no currentTrack');
            return;
          }
          _logger.log('AndroidAuto: startRadio: track=${track.name}, playerId=${player.playerId}');
          await provider.playRadio(player.playerId, track);
          _logger.log('AndroidAuto: startRadio: done');
          // Fetch updated queue after radio starts and populate AA queue
          _refreshQueueAfterDelay(provider, player.playerId);
        case 'cycleRepeat':
          final queue = await provider.getQueue(player.playerId);
          final currentMode = queue?.repeatMode ?? 'off';
          _logger.log('AndroidAuto: cycleRepeat: current=$currentMode');
          await provider.cycleRepeatMode(player.playerId, currentMode);
          // Track the new mode locally for icon update
          _repeatMode = switch (currentMode) {
            'off' => 'all',
            'all' => 'one',
            _ => 'off',
          };
        case 'switchPlayer':
          _logger.log('AndroidAuto: switchPlayer');
          onSwitchPlayer?.call();
          return;
      }
      // Re-broadcast playback state to update icons
      _refreshPlaybackState();
    } catch (e) {
      _logger.log('AndroidAuto: customAction error: $e');
    }
  }

  /// Re-broadcast current playback state to update custom action icons (AA)
  void _refreshPlaybackState() {
    final current = playbackState.value;
    playbackState.add(current.copyWith(
      controls: _controls,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
    ));
  }

  // --- Custom methods for Ensemble ---

  /// Play a URL with the given metadata
  Future<void> playUrl(String url, MediaItem item, {Map<String, String>? headers}) async {
    _currentMediaItem = item;
    mediaItem.add(item);

    try {
      final source = AudioSource.uri(
        Uri.parse(url),
        headers: headers,
        tag: item,
      );

      await _player.setAudioSource(source);
      await _player.play();
    } catch (e) {
      _logger.log('MassivAudioHandler: Error playing URL: $e');
      rethrow;
    }
  }

  /// Update the current media item (for notification display)
  /// This can be called when metadata arrives after playback starts
  @override
  Future<void> updateMediaItem(MediaItem item) async {
    _currentMediaItem = item;
    mediaItem.add(item);
  }

  /// Set volume (0.0 to 1.0)
  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  /// Set remote playback state (for controlling MA players without local playback)
  /// This shows the notification and responds to media controls without playing audio locally.
  Future<void> setRemotePlaybackState({
    required MediaItem item,
    required bool playing,
    Duration position = Duration.zero,
    Duration? duration,
  }) async {
    _clearErrorState();
    _isRemoteMode = true;
    // Sync favorite state only when track changes
    final trackId = '${item.id}';
    if (trackId != _lastTrackId) {
      _lastTrackId = trackId;
      _isFavorite = _autoProvider?.currentTrack?.favorite == true;
    }
    // Only activate audio session for the builtin player (local PCM playback).
    // Remote MA players manage their own audio — claiming focus on the phone
    // would pause them when another app (e.g. YouTube) plays.
    final builtinId = await SettingsService.getBuiltinPlayerId();
    if (!_isRemoteMode) return; // guard: clearRemotePlaybackState() called while awaiting
    final selectedId = _autoProvider?.selectedPlayer?.playerId;
    _isBuiltinPlayerActive = builtinId != null && selectedId == builtinId;
    if (playing && _isBuiltinPlayerActive) {
      final session = await AudioSession.instance;
      if (!_isRemoteMode) return; // guard: state may have changed
      await session.setActive(true);
    }
    // Only update mediaItem when the track actually changes to avoid
    // Android Auto reloading artwork on every play/pause toggle
    final trackChanged = _currentMediaItem?.id != item.id ||
        _currentMediaItem?.title != item.title ||
        _currentMediaItem?.artist != item.artist;
    if (trackChanged) {
      _logger.log('🎵 setRemotePlaybackState: track changed, calling mediaItem.add (${item.title})');
      _currentMediaItem = item;
      mediaItem.add(item);
    }

    playbackState.add(playbackState.value.copyWith(
      controls: _controls,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
    ));
  }

  /// Clear remote playback state and hide notification
  Future<void> clearRemotePlaybackState() async {
    _isRemoteMode = false;
    _currentMediaItem = null;

    playbackState.add(playbackState.value.copyWith(
      controls: [],
      processingState: AudioProcessingState.idle,
      playing: false,
    ));

    // Release audio focus
    final session = await AudioSession.instance;
    await session.setActive(false);
  }

  /// Switch to local playback mode (when builtin player is selected)
  void setLocalMode() {
    _isRemoteMode = false;
  }

  /// Update notification for local mode (builtin player) without switching to remote mode
  /// This allows the notification to show the correct player/track info while keeping
  /// pause working for local audio playback.
  Future<void> updateLocalModeNotification({
    required MediaItem item,
    required bool playing,
    Duration? duration,
    Duration? position,
  }) async {
    // Keep local mode - DON'T set _isRemoteMode = true

    // This method is only called for the builtin (local PCM) player
    _isBuiltinPlayerActive = true;

    // Claim audio focus only when transitioning to playing (not on every position update).
    // This avoids stealing focus back from other apps like Symphonium.
    if (playing && !playbackState.value.playing) {
      final session = await AudioSession.instance;
      await session.setActive(true);
    }

    // Only update mediaItem if it changed - avoid unnecessary notification refreshes
    // that cause blinking.
    if (_currentMediaItem?.id != item.id ||
        _currentMediaItem?.title != item.title ||
        _currentMediaItem?.artist != item.artist) {
      _logger.log('🎵 updateLocalModeNotification: track changed, calling mediaItem.add (${item.title})');
      _currentMediaItem = item;
      mediaItem.add(item);
    }

    // Also update playback state (playing/paused, position) for the notification
    // and foreground service activation. Use position from the PCM player or
    // provider's position tracker — caller passes what they have.
    playbackState.add(playbackState.value.copyWith(
      controls: _controls,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: position ?? playbackState.value.updatePosition,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
    ));
  }

  bool get isRemoteMode => _isRemoteMode;

  // --- Expose player state for provider ---

  bool get isPlaying => _player.playing;

  Duration get position => _player.position;

  Duration get duration => _player.duration ?? Duration.zero;

  double get volume => _player.volume;

  PlayerState get playerState => _player.playerState;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  MediaItem? get currentMediaItem => _currentMediaItem;

  // ---------------------------------------------------------------------------
  // Android Auto — media browsing and playback
  // ---------------------------------------------------------------------------

  /// Wire the provider in after the app has initialised.
  /// Called from _MusicAssistantAppState.initState().
  void setProvider(MusicAssistantProvider provider) {
    _autoProvider = provider;
    _logger.log('AndroidAuto: provider set');
  }

  // Convenience aliases for the delegate's media-ID constants (used in
  // getChildren dispatch and subscribeToChildren).
  static const _autoIdHome         = AndroidAutoBrowsingDelegate.autoIdHome;
  static const _autoIdMusic        = AndroidAutoBrowsingDelegate.autoIdMusic;
  static const _autoIdAudiobooks   = AndroidAutoBrowsingDelegate.autoIdAudiobooks;
  static const _autoIdPodcasts     = AndroidAutoBrowsingDelegate.autoIdPodcasts;
  static const _autoIdRadio        = AndroidAutoBrowsingDelegate.autoIdRadio;
  static const _autoIdPlaylists    = AndroidAutoBrowsingDelegate.autoIdPlaylists;
  static const _autoIdArtists      = AndroidAutoBrowsingDelegate.autoIdArtists;
  static const _autoIdAlbums       = AndroidAutoBrowsingDelegate.autoIdAlbums;
  static const _autoIdFavorites    = AndroidAutoBrowsingDelegate.autoIdFavorites;
  static const _autoIdFavArtists   = AndroidAutoBrowsingDelegate.autoIdFavArtists;
  static const _autoIdFavAlbums    = AndroidAutoBrowsingDelegate.autoIdFavAlbums;
  static const _autoIdFavTracks    = AndroidAutoBrowsingDelegate.autoIdFavTracks;
  static const _autoIdAbAuthors    = AndroidAutoBrowsingDelegate.autoIdAbAuthors;
  static const _autoIdAbBooks      = AndroidAutoBrowsingDelegate.autoIdAbBooks;
  static const _autoIdAbSeries     = AndroidAutoBrowsingDelegate.autoIdAbSeries;

  // Custom now-playing action buttons for Android Auto
  // Icons change based on current state for visual feedback
  static final _radioControl = MediaControl.custom(
    androidIcon: 'drawable/ic_auto_radio',
    label: 'Start Radio',
    name: 'startRadio',
  );

  MediaControl _shuffleControl() {
    return MediaControl.custom(
      androidIcon: _shuffleOn ? 'drawable/ic_auto_shuffle_on' : 'drawable/ic_auto_shuffle',
      label: 'Shuffle',
      name: 'toggleShuffle',
    );
  }

  MediaControl _favoriteControl() {
    return MediaControl.custom(
      androidIcon: _isFavorite ? 'drawable/ic_auto_favorite' : 'drawable/ic_auto_favorite_off',
      label: 'Favourite',
      name: 'toggleFavorite',
    );
  }

  MediaControl _repeatControl() {
    return MediaControl.custom(
      androidIcon: switch (_repeatMode) {
        'one' => 'drawable/ic_auto_repeat_one',
        'all' => 'drawable/ic_auto_repeat_all',
        _ => 'drawable/ic_auto_repeat',
      },
      label: 'Repeat',
      name: 'cycleRepeat',
    );
  }

  /// Controls list for playback state.
  /// Transport controls first (shown in notification), then AA custom actions.
  /// androidCompactActionIndices [0,1,2] = prev/play/next for compact notification.
  /// AA shows transport + custom actions (shuffle, favourite, radio, repeat).
  /// Uses MediaControl.pause as a placeholder — the system shows play or pause
  /// based on the `playing` boolean, not this list.
  List<MediaControl> get _controls => [
    MediaControl.skipToPrevious,
    MediaControl.pause,
    MediaControl.skipToNext,
    _shuffleControl(),
    if (!_isAndroidAutoConnected) _switchPlayerControl,
    _favoriteControl(),
    _radioControl,
    _repeatControl(),
  ];

  // Local state tracking for icon updates (synced after each action)
  bool _shuffleOn = false;
  bool _isFavorite = false;
  String _repeatMode = 'off';
  String? _lastTrackId;

  // Whether the currently selected player is the builtin (local PCM) player
  bool _isBuiltinPlayerActive = false;

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    onBrowseActivity?.call();

    final provider = _autoProvider;
    if (provider == null) {
      _logger.log('AndroidAuto: getChildren("$parentMediaId") — provider not set yet');
      return [];
    }

    // Ensure provider is connected — AA may browse before app is fully ready
    if (!provider.isConnected) {
      _logger.log('AndroidAuto: provider disconnected, starting reconnect');
      // Don't await — reconnection can take seconds and AA may timeout
      // getChildren. Cached data is served immediately; live API calls
      // inside builders will await their own reconnect if needed.
      provider.checkAndReconnect();
    }

    // Detect AA connection from any getChildren call (AA may cache the root
    // and only request subcategories, so we can't rely on the root request)
    if (!_isAndroidAutoConnected) {
      _logger.log('AndroidAuto: detected AA connection via getChildren("$parentMediaId")');
      _isAndroidAutoConnected = true;
      await _notifyAAConnectedNative();
      // Sync shuffle/repeat state from the queue so AA buttons show correctly
      final selectedId = provider.selectedPlayer?.playerId;
      if (selectedId != null) {
        final queue = await provider.getQueue(selectedId);
        if (queue != null) {
          _shuffleOn = queue.shuffle;
          _repeatMode = queue.repeatMode ?? 'off';
        }
      }
      _refreshPlaybackState();
      // Delegate player switching + queue restoration to onAAConnected
      // (same path as the native onAndroidAutoConnected event)
      onAAConnected?.call();
    }

    try {
      final result = await _autoGetChildren(provider, parentMediaId);
      _logger.log('AndroidAuto: getChildren "$parentMediaId" → ${result.length} items');
      return result;
    } catch (e, st) {
      _logger.log('AndroidAuto: getChildren error for "$parentMediaId": $e\n$st');
      return [];
    }
  }

  Future<List<MediaItem>> _autoGetChildren(
      MusicAssistantProvider provider, String parentMediaId) async {
    final b = _browsing;
    switch (parentMediaId) {
      // Root
      case AudioService.browsableRootId:
        return b.buildRoot();

      // Home — subcategory folders matching user's homescreen settings
      case _autoIdHome:
        return b.buildHome();

      // Music
      case _autoIdMusic:
        return b.buildMusicCategories();
      case _autoIdPlaylists:
        return b.buildPlaylistList(provider);
      case _autoIdArtists:
        return b.buildArtistList(provider);
      case _autoIdAlbums:
        return b.buildAlbumList(provider);
      case _autoIdFavorites:
        return b.buildFavoriteCategories();
      case _autoIdFavArtists:
        return b.buildFavArtists(provider);
      case _autoIdFavAlbums:
        return b.buildFavAlbums(provider);
      case _autoIdFavTracks:
        return b.buildFavTracks(provider);

      // Audiobooks
      case _autoIdAudiobooks:
        return b.buildAudiobookCategories();
      case _autoIdAbAuthors:
        return b.buildAudiobookAuthorList(provider);
      case _autoIdAbBooks:
        return b.buildAudiobookList(provider);
      case _autoIdAbSeries:
        return b.buildAudiobookSeriesList(provider);

      // Podcasts
      case _autoIdPodcasts:
        return b.buildPodcastList(provider);

      // Radio
      case _autoIdRadio:
        return b.buildRadioList(provider);

      default:
        // Home row content (home|recent-albums, etc.)
        if (parentMediaId.startsWith('home|')) {
          return b.buildHomeRowContent(provider, parentMediaId.substring(5));
        }
        return _autoBuildDynamicChildren(provider, parentMediaId);
    }
  }

  /// Route prefix-based dynamic media IDs (albums, playlists, artists, etc.)
  Future<List<MediaItem>> _autoBuildDynamicChildren(
      MusicAssistantProvider provider, String parentMediaId) async {
    final parts = parentMediaId.split('|');
    if (parts.length < 2) return [];
    final b = _browsing;

    switch (parts[0]) {
      case 'artists_alpha':
        if (parts.length >= 2) {
          return b.buildArtistList(provider, alphaFilter: parts[1]);
        }
      case 'albums_alpha':
        if (parts.length >= 2) {
          return b.buildAlbumList(provider, alphaFilter: parts[1]);
        }
      case 'tracks_alpha':
        if (parts.length >= 3) {
          final ctxKey = Uri.decodeComponent(parts[1]);
          final alpha = parts[2];
          final tracks = _autoTrackCache[ctxKey] ?? const <ma.Track>[];
          return b.buildTrackItems(provider, tracks, ctxKey, alphaFilter: alpha);
        }
      case 'playlist':
        if (parts.length >= 3) {
          return b.buildPlaylistTracks(provider, parts[1], parts[2]);
        }
      case 'album':
        if (parts.length >= 3) {
          return b.buildAlbumTracks(provider, parts[1], parts[2]);
        }
      case 'artist':
        final name = parts.sublist(1).join('|');
        return b.buildArtistAlbums(provider, name);
      case 'podcast':
        if (parts.length >= 3) {
          return b.buildPodcastEpisodes(provider, parts[1], parts[2]);
        }
      case 'ab_author':
        final authorName = parts.sublist(1).join('|');
        return b.buildAuthorAudiobooks(provider, authorName);
      case 'ab_series':
        final seriesPath = parts.sublist(1).join('|');
        return b.buildSeriesAudiobooks(provider, seriesPath);
    }

    _logger.log('AndroidAuto: unhandled parentMediaId "$parentMediaId"');
    return [];
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    if (!_autoChildrenSubjects.containsKey(parentMediaId)) {
      if (_autoChildrenSubjects.length >= _maxChildSubjectEntries) {
        final oldest = _autoChildrenSubjects.keys.first;
        _autoChildrenSubjects.remove(oldest)?.close();
      }
      _autoChildrenSubjects[parentMediaId] = BehaviorSubject.seeded({});
    }
    return _autoChildrenSubjects[parentMediaId]!.stream;
  }

  /// Notify Android Auto that children under [parentIds] may have changed.
  void invalidateAutoChildren(List<String> parentIds) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final id in parentIds) {
      _autoChildrenSubjects[id]?.add({'ts': ts});
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    final provider = _autoProvider;
    if (provider == null) {
      _logger.log('AndroidAuto: playFromMediaId called before provider is set');
      return;
    }

    if (!_isAndroidAutoConnected) {
      _logger.log('AndroidAuto: detected AA connection via playFromMediaId');
      _isAndroidAutoConnected = true;
      await _notifyAAConnectedNative();
      _refreshPlaybackState();
      // Delegate player switching + queue restoration to onAAConnected
      onAAConnected?.call();
    }

    final playerId = await _resolveReadyPlayerId(provider);
    if (playerId == null) {
      _logger.log('AndroidAuto: no ready player queue — cannot play');
      return;
    }

    // Auto-switch to the builtin (local) player when AA triggers playback
    if (provider.selectedPlayer?.playerId != playerId) {
      final builtinPlayer = provider.availablePlayersUnfiltered
          .where((p) => p.playerId == playerId)
          .firstOrNull;
      if (builtinPlayer != null) {
        _logger.log('AndroidAuto: switching to builtin player "${builtinPlayer.name}"');
        provider.selectPlayer(builtinPlayer);
      }
    }

    _logger.log('AndroidAuto: playFromMediaId $mediaId');
    _clearErrorState();

    try {
      if (mediaId.startsWith('artistradio|')) {
        final artistName = mediaId.substring('artistradio|'.length);
        final artist = SyncService.instance.cachedArtists
            .where((a) => a.name == artistName)
            .firstOrNull;
        if (artist == null) {
          _logger.log('AndroidAuto: Artist radio: artist "$artistName" not found');
          return;
        }
        _logger.log('AndroidAuto: Starting artist radio for "$artistName"');
        await provider.api?.playArtistRadio(playerId, artist);
        _refreshQueueAfterDelay(provider, playerId);
        return;
      }

      if (mediaId.startsWith('smartshuffle|')) {
        final ctxKey = mediaId.substring('smartshuffle|'.length);
        final trackList = _autoTrackCache[ctxKey];
        if (trackList == null || trackList.isEmpty) {
          _logger.log('AndroidAuto: Start Radio: no cached tracks for $ctxKey');
          return;
        }
        final seed = trackList[Random().nextInt(trackList.length)];
        try {
          await provider.api?.playRadio(playerId, seed);
          _refreshQueueAfterDelay(provider, playerId);
        } catch (e) {
          _logger.log('AndroidAuto: Start Radio failed, playing shuffled: $e');
          final shuffled = List<ma.Track>.from(trackList)..shuffle(Random());
          await provider.playTracks(playerId, shuffled, startIndex: 0);
          await provider.toggleShuffle(playerId, true);
          _populateQueue(provider, shuffled, 0);
        }
        return;
      }

      if (mediaId.startsWith('track|')) {
        // Format: track|{tProvider}|{tItemId}|{ctxType}|{ctxProvider}|{ctxId}
        final parts = mediaId.split('|');
        if (parts.length < 6) return;
        final tProvider = parts[1];
        final tItemId = parts[2];
        final ctxKey = parts.sublist(3).join('|');

        final trackList = _autoTrackCache[ctxKey];
        if (trackList == null || trackList.isEmpty) {
          _logger.log('AndroidAuto: cache miss for $ctxKey, playing single track');
          await provider.playTrack(
            playerId,
            ma.Track(itemId: tItemId, provider: tProvider, name: ''),
          );
          return;
        }

        final index = trackList.indexWhere(
          (t) => t.provider == tProvider && t.itemId == tItemId,
        );
        final startIdx = index < 0 ? 0 : index;
        await provider.playTracks(
          playerId,
          trackList,
          startIndex: startIdx,
        );
        _populateQueue(provider, trackList, startIdx);
        return;
      }

      if (mediaId.startsWith('radio|')) {
        // Format: radio|{provider}|{itemId}
        final parts = mediaId.split('|');
        if (parts.length < 3) return;
        if (provider.api == null) await provider.checkAndReconnect();
        if (provider.api == null) {
          _logger.log('AndroidAuto: no API, cannot play radio');
          return;
        }
        final station = provider.radioStations.firstWhere(
          (s) => s.provider == parts[1] && s.itemId == parts[2],
          orElse: () => provider.radioStationsUnfiltered.firstWhere(
            (s) => s.provider == parts[1] && s.itemId == parts[2],
            orElse: () => throw Exception('Radio station not found: $mediaId'),
          ),
        );
        await provider.api!.playRadioStation(playerId, station);
        return;
      }

      if (mediaId.startsWith('audiobook|')) {
        // Format: audiobook|{provider}|{itemId}
        final parts = mediaId.split('|');
        if (parts.length < 3) return;
        if (provider.api == null) {
          await provider.checkAndReconnect();
        }
        if (provider.api == null) {
          _logger.log('AndroidAuto: no API, cannot play audiobook');
          return;
        }
        final book = SyncService.instance.cachedAudiobooks.firstWhere(
          (b) => b.provider == parts[1] && b.itemId == parts[2],
          orElse: () => throw Exception('Audiobook not found: $mediaId'),
        );
        await provider.api!.playAudiobook(playerId, book);
        return;
      }

      if (mediaId.startsWith('podcast_ep|')) {
        // Format: podcast_ep|{epProvider}|{epId}|{podProvider}|{podId}
        // Legacy: podcast_ep|{provider}|{itemId}
        final parts = mediaId.split('|');
        if (parts.length < 3) return;
        if (provider.api == null) await provider.checkAndReconnect();
        if (provider.api == null) {
          _logger.log('AndroidAuto: no API, cannot play podcast');
          return;
        }

        // Set podcast name context so notification/AA shows it as artist
        if (parts.length >= 5) {
          final podcast = SyncService.instance.cachedPodcasts
              .where((p) => p.provider == parts[3] && p.itemId == parts[4])
              .firstOrNull;
          if (podcast != null) {
            provider.setCurrentPodcastName(podcast.name);
          }
        }

        // Use provider-specific URI (e.g. spotify--xxx://podcast_episode/id)
        // instead of library:// which fails for non-library items
        final uri = '${parts[1]}://podcast_episode/${parts[2]}';
        final episode = ma.MediaItem(
          itemId: parts[2],
          provider: parts[1],
          name: '',
          mediaType: ma.MediaType.podcastEpisode,
          uri: uri,
        );
        _logger.log('AndroidAuto: playing podcast episode URI: $uri');
        await provider.api!.playPodcastEpisode(playerId, episode);

        // Refresh queue after a delay (server needs time to build queue)
        _refreshQueueAfterDelay(provider, playerId);
        return;
      }
    } catch (e) {
      _logger.log('AndroidAuto: playFromMediaId error: $e');
      _setErrorState('Playback failed');
    }
  }

  /// Resolve a player that is actually ready to accept queue commands.
  ///
  /// On app resume, Android Auto may request playback before the builtin
  /// player registration/queue is fully available on the server. We poll for
  /// a short window and only return when queue access succeeds.
  Future<String?> _resolveReadyPlayerId(
    MusicAssistantProvider provider, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final builtinPlayerId = await SettingsService.getBuiltinPlayerId();
    _logger.log('AndroidAuto: _resolveReadyPlayerId — builtinId=$builtinPlayerId, selected=${provider.selectedPlayer?.playerId}');
    final deadline = DateTime.now().add(timeout);
    var delayMs = 250;

    while (DateTime.now().isBefore(deadline)) {
      try {
        await provider.checkAndReconnect();

        final allPlayers = await provider.getPlayers();
        Player? candidate;

        if (builtinPlayerId != null) {
          final idLower = builtinPlayerId.toLowerCase();
          candidate = allPlayers
              .where((p) => p.available &&
                  (p.playerId == builtinPlayerId ||
                   p.playerId.toLowerCase() == idLower ||
                   p.playerId.toLowerCase() == 'up$idLower'))
              .firstOrNull;
          if (candidate == null) {
            final ids = allPlayers.map((p) => '${p.name}(${p.playerId},avail=${p.available})').join(', ');
            _logger.log('AndroidAuto: builtin $builtinPlayerId not found in [$ids] — falling back to selected');
          }
        }

        candidate ??= allPlayers
            .where((p) => p.playerId == provider.selectedPlayer?.playerId && p.available)
            .firstOrNull;

        if (candidate != null) {
          if (provider.selectedPlayer?.playerId != candidate.playerId) {
            _logger.log('AndroidAuto: switching to ready player "${candidate.name}"');
            provider.selectPlayer(candidate);
          }

          await provider.getQueue(candidate.playerId);

          // Ensure Sendspin PCM streaming is alive before handing back
          // the player — without it the notification shows "playing"
          // but no audio reaches the speakers.
          if (!provider.isSendspinConnected) {
            _logger.log('AndroidAuto: Sendspin not connected, waiting...');
            throw Exception('Sendspin PCM not ready');
          }

          return candidate.playerId;
        }
      } catch (e) {
        _logger.log('AndroidAuto: waiting for ready queue: $e');
      }

      await Future.delayed(Duration(milliseconds: delayMs));
      delayMs = (delayMs * 2).clamp(250, 1500);
    }

    return null;
  }

  // Search race condition guard
  int _searchId = 0;

  @override
  Future<List<MediaItem>> search(String query,
      [Map<String, dynamic>? extras]) async {
    final provider = _autoProvider;
    if (provider == null || query.trim().isEmpty) return [];

    final searchId = ++_searchId;

    try {
      final results = await provider.searchWithCache(query);

      // Check for stale search
      if (searchId != _searchId) {
        _logger.log('AndroidAuto: ignoring stale search results for "$query"');
        return [];
      }

      final artists = (results['artists'] ?? []).whereType<ma.Artist>().take(5).toList();
      final albums = (results['albums'] ?? []).whereType<ma.Album>().take(5).toList();
      final tracks = (results['tracks'] ?? []).whereType<ma.Track>().toList();
      final ctxKey = 'search|${Uri.encodeComponent(query)}|';
      _cacheTrackList(ctxKey, tracks);

      final items = <MediaItem>[];

      // Group: Artists
      if (artists.isNotEmpty) {
        for (final a in artists) {
          items.add(MediaItem(
            id: 'artist|${a.name}',
            title: a.name,
            artUri: _browsing.artUri(provider, a),
            playable: false,
            extras: const {
              'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT': 'Artists',
            },
          ));
        }
      }

      // Group: Albums
      if (albums.isNotEmpty) {
        for (final a in albums) {
          items.add(MediaItem(
            id: 'album|${a.provider}|${a.itemId}',
            title: a.name,
            artist: a.artistsString,
            artUri: _browsing.artUri(provider, a),
            playable: false,
            extras: const {
              'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT': 'Albums',
            },
          ));
        }
      }

      // Group: Tracks
      for (final t in tracks) {
        final item = _browsing.trackItem(provider, t, ctxKey);
        items.add(MediaItem(
          id: item.id,
          title: item.title,
          artist: item.artist,
          album: item.album,
          duration: item.duration,
          artUri: item.artUri,
          playable: true,
          extras: const {
            'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT': 'Tracks',
          },
        ));
      }

      return items;
    } catch (e) {
      _logger.log('AndroidAuto: search error: $e');
      return [];
    }
  }

  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    final provider = _autoProvider;
    if (provider == null || query.trim().isEmpty) return;

    final playerId = await _resolveReadyPlayerId(provider);
    if (playerId == null) {
      _logger.log('AndroidAuto: playFromSearch: no ready player queue');
      return;
    }

    _logger.log('AndroidAuto: playFromSearch "$query"');
    _clearErrorState();

    try {
      final results = await provider.searchWithCache(query);
      final tracks = (results['tracks'] ?? []).whereType<ma.Track>().toList();
      if (tracks.isEmpty) {
        _logger.log('AndroidAuto: playFromSearch: no tracks found');
        return;
      }

      await provider.playTracks(playerId, tracks, startIndex: 0);
      _populateQueue(provider, tracks, 0);
    } catch (e) {
      _logger.log('AndroidAuto: playFromSearch error: $e');
      _setErrorState('Search playback failed');
    }
  }

  // --- Queue & error state helpers ---

  void _populateQueue(MusicAssistantProvider provider, List<ma.Track> tracks, int currentIndex) {
    final contextArtist = provider.currentPodcastName
        ?? provider.currentAudiobook?.authorsString;
    final items = tracks.map((t) {
      final artist = (t.artists == null || t.artists!.isEmpty)
          ? contextArtist
          : t.artistsString;
      return MediaItem(
        id: t.uri ?? t.itemId,
        title: t.name,
        artist: artist,
        album: t.album?.name,
        duration: t.duration,
        artUri: _browsing.artUri(provider, t),
      );
    }).toList();
    queue.add(items);
    playbackState.add(playbackState.value.copyWith(queueIndex: currentIndex));
  }

  void updateQueueIndex(int index) {
    if (playbackState.value.queueIndex == index) return;
    playbackState.add(playbackState.value.copyWith(queueIndex: index));
  }

  /// Sync an existing server queue to the MediaSession so AA shows the queue button.
  /// Called when AA connects while a queue is already loaded on the builtin player.
  void syncQueueToMediaSession(MusicAssistantProvider provider, List<ma.Track> tracks, int currentIndex) {
    if (tracks.isEmpty) return;
    _logger.log('AndroidAuto: syncing ${tracks.length} tracks to MediaSession (index=$currentIndex)');
    _populateQueue(provider, tracks, currentIndex);
    _refreshPlaybackState();
  }

  /// Fetch the server queue after a delay (e.g. after starting radio/podcast) and update AA queue.
  void _refreshQueueAfterDelay(MusicAssistantProvider provider, String playerId) {
    _queueRefreshTimer?.cancel();
    _queueRefreshTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final q = await provider.getQueue(playerId);
        if (q?.items == null || q!.items.isEmpty) return;
        final tracks = q.items.map((qi) => qi.track).toList();
        final currentIndex = q.currentIndex ?? 0;
        _shuffleOn = q.shuffle;
        _repeatMode = q.repeatMode ?? 'off';
        _logger.log('AndroidAuto: refreshed queue: ${tracks.length} tracks, shuffle=$_shuffleOn, repeat=$_repeatMode');
        _populateQueue(provider, tracks, currentIndex);
        _refreshPlaybackState();
      } catch (e) {
        _logger.log('AndroidAuto: failed to refresh queue: $e');
      }
    });
  }

  void _setErrorState(String message) {
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.error,
      errorMessage: message,
    ));
  }

  void _clearErrorState() {
    if (playbackState.value.processingState == AudioProcessingState.error) {
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.ready,
      ));
    }
  }

  // ---------------------------------------------------------------------------

  /// Dispose of resources and cancel all subscriptions
  Future<void> dispose() async {
    _queueRefreshTimer?.cancel();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _playbackEventSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    _autoTrackCache.clear();
    for (final s in _autoChildrenSubjects.values) {
      await s.close();
    }
    _autoChildrenSubjects.clear();
    await _player.dispose();
  }
}
