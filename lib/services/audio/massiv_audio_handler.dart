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

  // Android Auto: track queue cache — maps context key to ordered track list.
  // Populated during getChildren so playFromMediaId can queue the full album/playlist.
  static const _maxTrackCacheEntries = 50;
  final Map<String, List<ma.Track>> _autoTrackCache = {};

  void _cacheTrackList(String key, List<ma.Track> tracks) {
    _autoTrackCache[key] = tracks;
    while (_autoTrackCache.length > _maxTrackCacheEntries) {
      _autoTrackCache.remove(_autoTrackCache.keys.first);
    }
  }

  // Android Auto: subjects for subscribeToChildren
  final Map<String, BehaviorSubject<Map<String, dynamic>>> _autoChildrenSubjects = {};

  // Android Auto connection state — used to hide switch player button from controls
  bool _isAndroidAutoConnected = false;

  // Suppress auto-resume after audio route changes (e.g. BT/AA disconnect)
  bool _suppressResume = false;

  // Track whether music was actually playing before an interruption
  bool _wasPlayingBeforeInterruption = false;

  // Timestamp of last AA disconnect — used to suppress stream/start race condition
  DateTime? aaDisconnectedAt;

  // Android Auto method channel (Dart ↔ Native)
  static const _aaChannel = MethodChannel('com.collotsspot.ensemble/android_auto');

  // Custom control for switching players
  static final _switchPlayerControl = MediaControl.custom(
    androidIcon: 'drawable/ic_switch_player',
    label: 'Switch Player',
    name: 'switchPlayer',
  );

  MassivAudioHandler({required this.authManager}) {
    _init();
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
          _logger.log('AndroidAuto: car mode connected (broadcast)');
          _isAndroidAutoConnected = true;
          _aaChannel.invokeMethod('notifyAAConnected', null);
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
    // Stop action is used for switching players (both local and remote modes)
    onSwitchPlayer?.call();
    // Note: We don't actually stop playback - this button is repurposed for player switching
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
            if (libraryItemId != null) {
              await provider.removeFromFavorites(
                mediaType: 'track', libraryItemId: libraryItemId);
            }
          } else {
            _logger.log('AndroidAuto: toggleFavorite: adding');
            await provider.addToFavorites(
              mediaType: 'track', itemId: track.itemId, provider: track.provider);
          }
          _isFavorite = !_isFavorite;
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
  void setRemotePlaybackState({
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
    final selectedId = _autoProvider?.selectedPlayer?.playerId;
    _isBuiltinPlayerActive = builtinId != null && selectedId == builtinId;
    if (playing && _isBuiltinPlayerActive) {
      final session = await AudioSession.instance;
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
  void clearRemotePlaybackState() async {
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
  void updateLocalModeNotification({
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

  // Media ID constants — root categories
  static const _autoIdHome = 'cat|home';
  static const _autoIdMusic = 'cat|music';
  static const _autoIdAudiobooks = 'cat|audiobooks';
  static const _autoIdPodcasts = 'cat|podcasts';
  static const _autoIdRadio = 'cat|radio';

  // Media ID constants — Music subcategories
  static const _autoIdPlaylists = 'cat|playlists';
  static const _autoIdArtists = 'cat|artists';
  static const _autoIdAlbums = 'cat|albums';
  static const _autoIdFavorites = 'cat|favorites';

  // Media ID constants — Favourite subcategories
  static const _autoIdFavArtists = 'cat|fav_artists';
  static const _autoIdFavAlbums = 'cat|fav_albums';
  static const _autoIdFavTracks = 'cat|fav_tracks';

  // Media ID constants — Audiobook subcategories
  static const _autoIdAbAuthors = 'cat|ab_authors';
  static const _autoIdAbBooks = 'cat|ab_books';
  static const _autoIdAbSeries = 'cat|ab_series';

  // Android Auto content style hints
  static const _gridHints = {
    'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2,
    'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 2,
  };

  // Icon URIs for category items
  static const _iconPkg = 'com.collotsspot.ensemble';
  static final _iconHome = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_home');
  static final _iconMusic = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_music');
  static final _iconBook = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_book');
  static final _iconPodcast = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_podcast');
  static final _iconRadio = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_radio');
  static final _iconArtist = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_artist');
  static final _iconAlbum = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_album');
  static final _iconPlaylist = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_playlist');
  static final _iconFavorite = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_favorite');
  static final _iconStartRadio = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_radio');

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
      _aaChannel.invokeMethod('notifyAAConnected', null);
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
      // Auto-select builtin player so playback goes to the phone
      final playerId = await SettingsService.getBuiltinPlayerId();
      if (playerId != null && provider.selectedPlayer?.playerId != playerId) {
        final builtinPlayer = provider.availablePlayersUnfiltered
            .where((p) => p.playerId == playerId)
            .firstOrNull;
        if (builtinPlayer != null) {
          _logger.log('AndroidAuto: auto-selecting builtin player "${builtinPlayer.name}"');
          provider.selectPlayer(builtinPlayer);
        }
      }
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
    switch (parentMediaId) {
      // Root
      case AudioService.browsableRootId:
        return _autoBuildRoot();

      // Home — subcategory folders matching user's homescreen settings
      case _autoIdHome:
        return _autoBuildHome();

      // Music
      case _autoIdMusic:
        return _autoBuildMusicCategories();
      case _autoIdPlaylists:
        return _autoBuildPlaylistList(provider);
      case _autoIdArtists:
        return _autoBuildArtistList(provider);
      case _autoIdAlbums:
        return _autoBuildAlbumList(provider);
      case _autoIdFavorites:
        return _autoBuildFavoriteCategories();
      case _autoIdFavArtists:
        return _autoBuildFavArtists(provider);
      case _autoIdFavAlbums:
        return _autoBuildFavAlbums(provider);
      case _autoIdFavTracks:
        return _autoBuildFavTracks(provider);

      // Audiobooks
      case _autoIdAudiobooks:
        return _autoBuildAudiobookCategories();
      case _autoIdAbAuthors:
        return _autoBuildAudiobookAuthorList(provider);
      case _autoIdAbBooks:
        return _autoBuildAudiobookList(provider);
      case _autoIdAbSeries:
        return _autoBuildAudiobookSeriesList(provider);

      // Podcasts
      case _autoIdPodcasts:
        return _autoBuildPodcastList(provider);

      // Radio
      case _autoIdRadio:
        return _autoBuildRadioList(provider);

      default:
        // Home row content (home|recent-albums, etc.)
        if (parentMediaId.startsWith('home|')) {
          return _autoBuildHomeRowContent(provider, parentMediaId.substring(5));
        }
        return _autoBuildDynamicChildren(provider, parentMediaId);
    }
  }

  /// Route prefix-based dynamic media IDs (albums, playlists, artists, etc.)
  Future<List<MediaItem>> _autoBuildDynamicChildren(
      MusicAssistantProvider provider, String parentMediaId) async {
    final parts = parentMediaId.split('|');
    if (parts.length < 2) return [];

    switch (parts[0]) {
      case 'playlist':
        if (parts.length >= 3) {
          return _autoBuildPlaylistTracks(provider, parts[1], parts[2]);
        }
      case 'album':
        if (parts.length >= 3) {
          return _autoBuildAlbumTracks(provider, parts[1], parts[2]);
        }
      case 'artist':
        final name = parts.sublist(1).join('|');
        return _autoBuildArtistAlbums(provider, name);
      case 'podcast':
        if (parts.length >= 3) {
          return _autoBuildPodcastEpisodes(provider, parts[1], parts[2]);
        }
      case 'ab_author':
        final authorName = parts.sublist(1).join('|');
        return _autoBuildAuthorAudiobooks(provider, authorName);
      case 'ab_series':
        final seriesPath = parts.sublist(1).join('|');
        return _autoBuildSeriesAudiobooks(provider, seriesPath);
    }

    _logger.log('AndroidAuto: unhandled parentMediaId "$parentMediaId"');
    return [];
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    _autoChildrenSubjects[parentMediaId] ??= BehaviorSubject.seeded({});
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
      _aaChannel.invokeMethod('notifyAAConnected', null);
      _refreshPlaybackState();
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
    final deadline = DateTime.now().add(timeout);
    var delayMs = 250;

    while (DateTime.now().isBefore(deadline)) {
      try {
        await provider.checkAndReconnect();

        final allPlayers = await provider.getPlayers();
        ma.Player? candidate;

        if (builtinPlayerId != null) {
          candidate = allPlayers
              .where((p) => p.playerId == builtinPlayerId && p.available)
              .firstOrNull;
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
      const ctxKey = 'search||';
      _cacheTrackList(ctxKey, tracks);

      final items = <MediaItem>[];

      // Group: Artists
      if (artists.isNotEmpty) {
        for (final a in artists) {
          items.add(MediaItem(
            id: 'artist|${a.name}',
            title: a.name,
            artUri: _autoArtUri(provider, a),
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
            artUri: _autoArtUri(provider, a),
            playable: false,
            extras: const {
              'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT': 'Albums',
            },
          ));
        }
      }

      // Group: Tracks
      for (final t in tracks) {
        final item = _autoTrackItem(provider, t, ctxKey);
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
        artUri: _autoArtUri(provider, t),
      );
    }).toList();
    queue.add(items);
    playbackState.add(playbackState.value.copyWith(queueIndex: currentIndex));
  }

  void updateQueueIndex(int index) {
    if (playbackState.value.queueIndex == index) return;
    playbackState.add(playbackState.value.copyWith(queueIndex: index));
  }

  /// Fetch the server queue after a delay (e.g. after starting radio/podcast) and update AA queue.
  void _refreshQueueAfterDelay(MusicAssistantProvider provider, String playerId) {
    Future.delayed(const Duration(seconds: 2), () async {
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

  // --- Root & category builders ---

  List<MediaItem> _autoBuildRoot() {
    return [
      MediaItem(id: _autoIdHome, title: 'Home', playable: false,
          artUri: _iconHome),
      MediaItem(id: _autoIdMusic, title: 'Music', playable: false,
          artUri: _iconMusic),
      MediaItem(id: _autoIdAudiobooks, title: 'Audiobooks', playable: false,
          artUri: _iconBook),
      MediaItem(id: _autoIdPodcasts, title: 'Podcasts', playable: false,
          artUri: _iconPodcast, extras: _gridHints),
      MediaItem(id: _autoIdRadio, title: 'Radio', playable: false,
          artUri: _iconRadio, extras: _gridHints),
    ];
  }

  // Row ID → display title mapping
  static const _homeRowTitles = {
    'recent-albums': 'Recent Albums',
    'discover-artists': 'Discover Artists',
    'discover-albums': 'Discover Albums',
    'continue-listening': 'Continue Listening',
    'discover-audiobooks': 'Discover Audiobooks',
    'discover-series': 'Discover Series',
    'favorite-albums': 'Favourite Albums',
    'favorite-artists': 'Favourite Artists',
    'favorite-tracks': 'Favourite Tracks',
    'favorite-playlists': 'Favourite Playlists',
    'favorite-radio-stations': 'Favourite Radio',
    'favorite-podcasts': 'Favourite Podcasts',
  };

  /// Home shows subcategory folders matching the user's homescreen settings.
  Future<List<MediaItem>> _autoBuildHome() async {
    final rowOrder = await SettingsService.getHomeRowOrder();
    final items = <MediaItem>[];

    for (final rowId in rowOrder) {
      if (!await _isHomeRowEnabled(rowId)) continue;
      final title = _homeRowTitles[rowId];
      if (title == null) continue; // skip discovery rows for now
      items.add(MediaItem(
        id: 'home|$rowId',
        title: title,
        playable: false,
        extras: _gridHints,
      ));
    }

    _logger.log('AndroidAuto: Home built ${items.length} rows');
    return items;
  }

  Future<bool> _isHomeRowEnabled(String rowId) async {
    switch (rowId) {
      case 'recent-albums': return SettingsService.getShowRecentAlbums();
      case 'discover-artists': return SettingsService.getShowDiscoverArtists();
      case 'discover-albums': return SettingsService.getShowDiscoverAlbums();
      case 'continue-listening': return SettingsService.getShowContinueListeningAudiobooks();
      case 'discover-audiobooks': return SettingsService.getShowDiscoverAudiobooks();
      case 'discover-series': return SettingsService.getShowDiscoverSeries();
      case 'favorite-albums': return SettingsService.getShowFavoriteAlbums();
      case 'favorite-artists': return SettingsService.getShowFavoriteArtists();
      case 'favorite-tracks': return SettingsService.getShowFavoriteTracks();
      case 'favorite-playlists': return SettingsService.getShowFavoritePlaylists();
      case 'favorite-radio-stations': return SettingsService.getShowFavoriteRadioStations();
      case 'favorite-podcasts': return SettingsService.getShowFavoritePodcasts();
      default: return false;
    }
  }

  /// Build content for a specific home row.
  Future<List<MediaItem>> _autoBuildHomeRowContent(
      MusicAssistantProvider provider, String rowId) async {
    switch (rowId) {
      case 'recent-albums':
        var albums = await provider.getRecentAlbumsWithCache();
        if (albums.isEmpty) albums = SyncService.instance.cachedAlbums.take(20).toList();
        return albums.take(20).map((a) => MediaItem(
          id: 'album|${a.provider}|${a.itemId}',
          title: a.name, artist: a.artistsString,
          artUri: _autoArtUri(provider, a), playable: false,
        )).toList();

      case 'discover-artists':
        var artists = await provider.getDiscoverArtistsWithCache();
        if (artists.isEmpty) artists = SyncService.instance.cachedArtists.take(10).toList();
        return artists.take(10).map((a) => MediaItem(
          id: 'artist|${a.name}',
          title: a.name,
          artUri: _autoArtUri(provider, a), playable: false,
        )).toList();

      case 'discover-albums':
        final albums = await provider.getDiscoverAlbumsWithCache();
        return albums.take(20).map((a) => MediaItem(
          id: 'album|${a.provider}|${a.itemId}',
          title: a.name, artist: a.artistsString,
          artUri: _autoArtUri(provider, a), playable: false,
        )).toList();

      case 'continue-listening':
        final books = await provider.getInProgressAudiobooksWithCache();
        return books.map((b) => MediaItem(
          id: 'audiobook|${b.provider}|${b.itemId}',
          title: b.name, artist: b.authorsString,
          artUri: _autoArtUri(provider, b), playable: true,
          extras: _audiobookExtras(b),
        )).toList();

      case 'discover-audiobooks':
        final books = await provider.getDiscoverAudiobooksWithCache();
        return books.map((b) => MediaItem(
          id: 'audiobook|${b.provider}|${b.itemId}',
          title: b.name, artist: b.authorsString,
          artUri: _autoArtUri(provider, b), playable: true,
          extras: _audiobookExtras(b),
        )).toList();

      case 'discover-series':
        return _autoBuildAudiobookSeriesList(provider);

      case 'favorite-albums':
        final albums = await provider.getFavoriteAlbums();
        return albums.map((a) => MediaItem(
          id: 'album|${a.provider}|${a.itemId}',
          title: a.name, artist: a.artistsString,
          artUri: _autoArtUri(provider, a), playable: false,
        )).toList();

      case 'favorite-artists':
        final artists = await provider.getFavoriteArtists();
        return artists.map((a) => MediaItem(
          id: 'artist|${a.name}',
          title: a.name,
          artUri: _autoArtUri(provider, a), playable: false,
        )).toList();

      case 'favorite-tracks':
        final tracks = await provider.getFavoriteTracks();
        const ctxKey = 'favs||';
        _cacheTrackList(ctxKey, tracks);
        return tracks.map((t) => _autoTrackItem(provider, t, ctxKey)).toList();

      case 'favorite-playlists':
        final playlists = await provider.getFavoritePlaylists();
        return playlists.map((p) => MediaItem(
          id: 'playlist|${p.provider}|${p.itemId}',
          title: p.name, artist: p.owner,
          artUri: _autoArtUri(provider, p), playable: false,
        )).toList();

      case 'favorite-radio-stations':
        final stations = await provider.getFavoriteRadioStations();
        return stations.map((s) => MediaItem(
          id: 'radio|${s.provider}|${s.itemId}',
          title: s.name,
          artUri: _autoArtUri(provider, s), playable: true,
        )).toList();

      case 'favorite-podcasts':
        // Use cached podcasts filtered by favorite
        final podcasts = SyncService.instance.cachedPodcasts
            .where((p) => p.favorite == true).toList();
        return podcasts.map((p) => MediaItem(
          id: 'podcast|${p.provider}|${p.itemId}',
          title: p.name,
          artUri: _autoArtUri(provider, p), playable: false,
        )).toList();

      default:
        return [];
    }
  }

  List<MediaItem> _autoBuildMusicCategories() {
    return [
      MediaItem(id: _autoIdArtists, title: 'Artists', playable: false,
          artUri: _iconArtist, extras: _gridHints),
      MediaItem(id: _autoIdAlbums, title: 'Albums', playable: false,
          artUri: _iconAlbum, extras: _gridHints),
      MediaItem(id: _autoIdPlaylists, title: 'Playlists', playable: false,
          artUri: _iconPlaylist, extras: _gridHints),
      MediaItem(id: _autoIdFavorites, title: 'Favourites', playable: false,
          artUri: _iconFavorite),
    ];
  }

  List<MediaItem> _autoBuildAudiobookCategories() {
    return [
      MediaItem(id: _autoIdAbAuthors, title: 'Authors', playable: false,
          artUri: _iconArtist),
      MediaItem(id: _autoIdAbBooks, title: 'Books', playable: false,
          artUri: _iconBook, extras: _gridHints),
      MediaItem(id: _autoIdAbSeries, title: 'Series', playable: false,
          artUri: _iconBook, extras: _gridHints),
    ];
  }

  // --- Music builders ---

  List<MediaItem> _autoBuildFavoriteCategories() {
    return [
      MediaItem(id: _autoIdFavArtists, title: 'Favourite Artists',
          playable: false, artUri: _iconArtist),
      MediaItem(id: _autoIdFavAlbums, title: 'Favourite Albums',
          playable: false, artUri: _iconAlbum, extras: _gridHints),
      MediaItem(id: _autoIdFavTracks, title: 'Favourite Tracks',
          playable: false, artUri: _iconFavorite),
    ];
  }

  Future<List<MediaItem>> _autoBuildFavArtists(
      MusicAssistantProvider provider) async {
    final artists = await provider.getFavoriteArtists();
    return artists.map((a) => MediaItem(
      id: 'artist|${a.name}', title: a.name,
      artUri: _autoArtUri(provider, a), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildFavAlbums(
      MusicAssistantProvider provider) async {
    final albums = await provider.getFavoriteAlbums();
    return albums.map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}', title: a.name, artist: a.artistsString,
      artUri: _autoArtUri(provider, a), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildFavTracks(
      MusicAssistantProvider provider) async {
    final tracks = await provider.getFavoriteTracks();
    _logger.log('AndroidAuto: Fav tracks returned ${tracks.length} tracks');
    const ctxKey = 'favs||';
    _cacheTrackList(ctxKey, tracks);
    final items = tracks.map((t) => _autoTrackItem(provider, t, ctxKey)).toList();
    if (items.isNotEmpty) items.insert(0, _autoStartRadioItem(ctxKey));
    return items;
  }

  Future<List<MediaItem>> _autoBuildPlaylistList(MusicAssistantProvider provider) async {
    var playlists = SyncService.instance.cachedPlaylists;
    if (playlists.isEmpty) {
      _logger.log('AndroidAuto: cachedPlaylists empty, loading from cache');
      await SyncService.instance.loadFromCache();
      playlists = SyncService.instance.cachedPlaylists;
    }
    _logger.log('AndroidAuto: Playlists: ${playlists.length}');
    return playlists.map((p) => MediaItem(
      id: 'playlist|${p.provider}|${p.itemId}',
      title: p.name,
      artist: p.owner,
      artUri: _autoArtUri(provider, p),
      playable: false,
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildPlaylistTracks(
      MusicAssistantProvider provider, String plProvider, String plItemId) async {
    final tracks =
        await provider.getPlaylistTracksWithCache(plProvider, plItemId);
    final ctxKey = 'plist|$plProvider|$plItemId';
    _cacheTrackList(ctxKey, tracks);
    final items = tracks.map((t) => _autoTrackItem(provider, t, ctxKey)).toList();
    if (items.isNotEmpty) items.insert(0, _autoStartRadioItem(ctxKey));
    return items;
  }

  Future<List<MediaItem>> _autoBuildArtistList(MusicAssistantProvider provider) async {
    var artists = SyncService.instance.cachedArtists;
    if (artists.isEmpty) {
      _logger.log('AndroidAuto: cachedArtists empty, loading from cache');
      await SyncService.instance.loadFromCache();
      artists = SyncService.instance.cachedArtists;
    }
    _logger.log('AndroidAuto: Artists: ${artists.length}');
    return Future.wait(artists.map((a) async {
      final imageUrl = await provider.getArtistImageUrlWithFallback(a, size: 256);
      return MediaItem(
        id: 'artist|${a.name}',
        title: a.name,
        artUri: imageUrl != null ? _contentUriForArtwork(imageUrl) : null,
        playable: false,
      );
    }));
  }

  Future<List<MediaItem>> _autoBuildArtistAlbums(
      MusicAssistantProvider provider, String artistName) async {
    var albums = await provider.getArtistAlbumsWithCache(artistName);
    if (albums.isEmpty) {
      // Fallback to library if API unavailable
      albums = provider.getArtistAlbumsFromLibrary(artistName);
    }
    _logger.log('AndroidAuto: Artist "$artistName" albums: ${albums.length}');
    return [
      MediaItem(
        id: 'artistradio|$artistName',
        title: 'Start Radio',
        artUri: _iconRadio,
        playable: true,
      ),
      ...albums.map((a) => MediaItem(
        id: 'album|${a.provider}|${a.itemId}',
        title: a.name,
        artist: a.artistsString,
        artUri: _autoArtUri(provider, a),
        playable: false,
      )),
    ];
  }

  Future<List<MediaItem>> _autoBuildAlbumList(MusicAssistantProvider provider) async {
    var albums = SyncService.instance.cachedAlbums;
    if (albums.isEmpty) {
      _logger.log('AndroidAuto: cachedAlbums empty, loading from cache');
      await SyncService.instance.loadFromCache();
      albums = SyncService.instance.cachedAlbums;
    }
    _logger.log('AndroidAuto: Albums: ${albums.length}');
    return albums.map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}',
      title: a.name,
      artist: a.artistsString,
      artUri: _autoArtUri(provider, a),
      playable: false,
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildAlbumTracks(
      MusicAssistantProvider provider, String alProvider, String alItemId) async {
    final tracks =
        await provider.getAlbumTracksWithCache(alProvider, alItemId);
    _logger.log('AndroidAuto: Album $alProvider/$alItemId tracks: ${tracks.length}');
    final ctxKey = 'album|$alProvider|$alItemId';
    _cacheTrackList(ctxKey, tracks);
    final items = tracks.map((t) => _autoTrackItem(provider, t, ctxKey)).toList();
    if (items.isNotEmpty) items.insert(0, _autoStartRadioItem(ctxKey));
    return items;
  }

  // --- Audiobook builders ---

  List<MediaItem> _autoBuildAudiobookAuthorList(
      MusicAssistantProvider provider) {
    final books = SyncService.instance.cachedAudiobooks;
    final seen = <String>{};
    final items = <MediaItem>[];
    for (final b in books) {
      final author = b.authorsString;
      if (seen.add(author)) {
        items.add(MediaItem(
          id: 'ab_author|$author',
          title: author,
          artUri: _autoArtUri(provider, b),
          playable: false,
        ));
      }
    }
    _logger.log('AndroidAuto: Audiobook authors: ${items.length}');
    return items;
  }

  List<MediaItem> _autoBuildAuthorAudiobooks(
      MusicAssistantProvider provider, String authorName) {
    final books = SyncService.instance.cachedAudiobooks
        .where((b) => b.authorsString == authorName)
        .toList();
    return books.map((b) => MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: b.name,
      artist: b.authorsString,
      artUri: _autoArtUri(provider, b),
      playable: true,
      extras: _audiobookExtras(b),
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildAudiobookList(MusicAssistantProvider provider) async {
    var books = SyncService.instance.cachedAudiobooks;
    if (books.isEmpty) {
      // Sync cache may not be loaded yet — wait for it
      _logger.log('AndroidAuto: cachedAudiobooks empty, loading from cache');
      await SyncService.instance.loadFromCache();
      books = SyncService.instance.cachedAudiobooks;
    }
    _logger.log('AndroidAuto: Books: ${books.length}');
    // Sort alphabetically and cap to avoid overwhelming Android Auto
    books.sort((a, b) => a.name.compareTo(b.name));
    return books.take(500).map((b) => MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: b.name,
      artist: b.authorsString,
      artUri: _autoArtUri(provider, b),
      playable: true,
      extras: _audiobookExtras(b),
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildAudiobookSeriesList(
      MusicAssistantProvider provider) async {
    final series = await provider.getDiscoverSeriesWithCache();
    _logger.log('AndroidAuto: Audiobook series: ${series.length}');
    final items = <MediaItem>[];
    for (final s in series) {
      // Use first book's artwork instead of series mosaic thumbnail
      Uri? artUri;
      var cachedBooks = provider.getCachedSeriesAudiobooks(s.id);
      if (cachedBooks == null || cachedBooks.isEmpty) {
        // Fetch books for this series (result is cached for future use)
        try {
          cachedBooks = await provider.getSeriesAudiobooksWithCache(s.id);
        } catch (_) {}
      }
      if (cachedBooks != null && cachedBooks.isNotEmpty) {
        artUri = _autoArtUri(provider, cachedBooks.first);
      }
      items.add(MediaItem(
        id: 'ab_series|${s.id}',
        title: s.name,
        artUri: artUri,
        playable: false,
      ));
    }
    return items;
  }

  Future<List<MediaItem>> _autoBuildSeriesAudiobooks(
      MusicAssistantProvider provider, String seriesPath) async {
    final books = await provider.getSeriesAudiobooksWithCache(seriesPath);
    return books.map((b) => MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: b.name,
      artist: b.authorsString,
      artUri: _autoArtUri(provider, b),
      playable: true,
      extras: _audiobookExtras(b),
    )).toList();
  }

  // --- Podcast builders ---

  List<MediaItem> _autoBuildPodcastList(MusicAssistantProvider provider) {
    final podcasts = SyncService.instance.cachedPodcasts;
    _logger.log('AndroidAuto: Podcasts: ${podcasts.length}');
    return podcasts.map((p) => MediaItem(
      id: 'podcast|${p.provider}|${p.itemId}',
      title: p.name,
      artUri: _autoArtUri(provider, p),
      playable: false,
    )).toList();
  }

  Future<List<MediaItem>> _autoBuildPodcastEpisodes(
      MusicAssistantProvider provider, String podProvider, String podItemId) async {
    final episodes = await provider.getPodcastEpisodesWithCache(
      podItemId,
      provider: podProvider,
    );
    // Look up podcast name to show as artist for each episode
    final podcast = SyncService.instance.cachedPodcasts
        .where((p) => p.itemId == podItemId && p.provider == podProvider)
        .firstOrNull;
    // Encode podcast context in episode ID: podcast_ep|epProvider|epId|podProvider|podId
    return episodes.map((e) => MediaItem(
      id: 'podcast_ep|${e.provider}|${e.itemId}|$podProvider|$podItemId',
      title: e.name,
      artist: podcast?.name,
      duration: e.duration,
      artUri: _autoArtUri(provider, e),
      playable: true,
    )).toList();
  }

  // --- Radio builder ---

  Future<List<MediaItem>> _autoBuildRadioList(MusicAssistantProvider provider) async {
    // Radio stations are lazily loaded — trigger load if empty
    if (provider.radioStations.isEmpty) {
      _logger.log('AndroidAuto: Radio empty, loading stations');
      await provider.loadRadioStations();
    }
    final stations = provider.radioStations;
    _logger.log('AndroidAuto: Radio stations: ${stations.length}');
    return stations.map((s) => MediaItem(
      id: 'radio|${s.provider}|${s.itemId}',
      title: s.name,
      artUri: _autoArtUri(provider, s),
      playable: true,
    )).toList();
  }

  // --- Helpers ---

  Map<String, dynamic>? _audiobookExtras(ma.Audiobook book) {
    if (book.progress <= 0 && book.fullyPlayed != true) return null;
    return {
      'android.media.extra.PLAYBACK_STATUS': book.fullyPlayed == true ? 2 : 1,
      'android.media.extra.PLAYBACK_STATUS_COMPLETION_PERCENTAGE': book.progress,
    };
  }

  MediaItem _autoStartRadioItem(String ctxKey) {
    return MediaItem(
      id: 'smartshuffle|$ctxKey',
      title: 'Start Radio',
      artUri: _iconStartRadio,
      playable: true,
    );
  }

  MediaItem _autoTrackItem(
      MusicAssistantProvider provider, ma.Track t, String ctxKey) {
    final firstArtist = t.artists?.isNotEmpty == true ? t.artists!.first.name : null;
    return MediaItem(
      id: 'track|${t.provider}|${t.itemId}|$ctxKey',
      title: t.name,
      artist: t.artistsString,
      album: t.album?.name,
      duration: t.duration,
      artUri: _autoArtUri(provider, t),
      playable: true,
      extras: firstArtist != null ? {
        'android.media.metadata.SUBTITLE_LINK_MEDIA_ID': 'artist|$firstArtist',
      } : null,
    );
  }

  static const _artworkAuthority = 'com.collotsspot.ensemble.artwork';

  Uri? _autoArtUri(MusicAssistantProvider provider, ma.MediaItem item) {
    final url = provider.getImageUrl(item, size: 256);
    if (url == null) return null;
    return _contentUriForArtwork(url);
  }

  static Uri? _contentUriForArtwork(String httpUrl) {
    final encoded = base64Url.encode(utf8.encode(httpUrl));
    return Uri.parse('content://$_artworkAuthority/$encoded');
  }

  // ---------------------------------------------------------------------------

  /// Dispose of resources and cancel all subscriptions
  Future<void> dispose() async {
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
