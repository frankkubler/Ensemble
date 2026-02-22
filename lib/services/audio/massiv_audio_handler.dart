import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../debug_logger.dart';
import '../auth/auth_manager.dart';
import '../settings_service.dart';
import '../sync_service.dart';
import '../../providers/music_assistant_provider.dart';
import '../../models/media_item.dart' as ma;

/// Cache for Android Auto artwork to improve loading performance
class AndroidAutoArtworkCache {
  final Map<String, Uri> _cache = {};
  final _logger = DebugLogger();

  /// Precache artwork for a list of media items
  Future<void> precacheCategory(
      MusicAssistantProvider provider,
      List<ma.MediaItem> items) async {
    final futures = <Future<void>>[];
    
    for (final item in items.take(50)) {
      final key = '${item.provider}|${item.itemId}';
      if (!_cache.containsKey(key)) {
        futures.add(() async {
          try {
            final url = provider.getImageUrl(item, size: 256);
            if (url != null) {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                _cache[key] = uri;
              }
            }
          } catch (e) {
            _logger.log('AndroidAuto: Cache error for $key: $e');
          }
        }());
      }
      
      // Process in batches to avoid overwhelming the system
      if (futures.length >= 10) {
        await Future.wait(futures);
        futures.clear();
      }
    }
    
    // Process remaining
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  /// Get cached artwork URI
  Uri? getCached(String provider, String itemId) {
    return _cache['$provider|$itemId'];
  }

  /// Clear the cache
  void clear() {
    _cache.clear();
  }
}

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

  // Track whether we're in remote control mode (controlling MA player, not playing locally)
  bool _isRemoteMode = false;

  // Android Auto: provider reference (set after app initialises)
  MusicAssistantProvider? _autoProvider;

  // Android Auto: track queue cache — maps context key to ordered track list.
  // Populated during getChildren so playFromMediaId can queue the full album/playlist.
  final Map<String, List<ma.Track>> _autoTrackCache = {};

  // Android Auto: subjects for subscribeToChildren
  final Map<String, BehaviorSubject<Map<String, dynamic>>> _autoChildrenSubjects = {};

  // Android Auto: pagination constants
  static const int _pageSize = 50;
  static const int _maxItemsWithoutPagination = 500;  // Increased from 200 to show more items with alphabetical separators

  // Android Auto: artwork cache for faster loading
  static final _artworkCache = AndroidAutoArtworkCache();

  // Custom control for switching players (uses stop action with custom icon)
  static const _switchPlayerControl = MediaControl(
    androidIcon: 'drawable/ic_switch_player',
    label: 'Switch Player',
    action: MediaAction.stop,
  );

  MassivAudioHandler({required this.authManager}) {
    _init();
  }

  Future<void> _init() async {
    // Configure audio session
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // Handle audio interruptions
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _player.setVolume(0.5);
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            pause();
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _player.setVolume(1.0);
            break;
          case AudioInterruptionType.pause:
            play();
            break;
          case AudioInterruptionType.unknown:
            break;
        }
      }
    });

    // Handle becoming noisy (headphones unplugged)
    _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
      pause();
    });

    // Broadcast playback state changes
    _playbackEventSubscription = _player.playbackEventStream.listen(_broadcastState);

    // Broadcast current media item changes
    _currentIndexSubscription = _player.currentIndexStream.listen((_) {
      if (_currentMediaItem != null) {
        mediaItem.add(_currentMediaItem);
      }
    });
  }

  /// Broadcast the current playback state to the system
  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;

    playbackState.add(playbackState.value.copyWith(
      // Configure notification action buttons
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        _switchPlayerControl, // Switch player button
      ],
      // System-level actions (for headphones, car stereos, etc.)
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      // Which buttons to show in compact notification (max 3)
      // Show: play/pause (1), skip-next (2), switch-player (3)
      androidCompactActionIndices: const [1, 2, 3],
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
    if (_isRemoteMode) {
      onPlay?.call();
    } else {
      await _player.play();
    }
  }

  @override
  Future<void> pause() async {
    if (_isRemoteMode) {
      onPause?.call();
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
  }) {
    _isRemoteMode = true;
    _currentMediaItem = item;
    mediaItem.add(item);

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        _switchPlayerControl,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.stop,
      },
      // Which buttons to show in compact notification (max 3)
      // Show: play/pause (1), skip-next (2), switch-player (3)
      androidCompactActionIndices: const [1, 2, 3],
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
    ));
  }

  /// Clear remote playback state and hide notification
  void clearRemotePlaybackState() {
    _isRemoteMode = false;
    _currentMediaItem = null;

    playbackState.add(playbackState.value.copyWith(
      controls: [],
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
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
  }) {
    // Keep local mode - DON'T set _isRemoteMode = true
    // Only update mediaItem if it changed - avoid unnecessary notification refreshes
    // that cause blinking. The playbackState is managed by _broadcastState which
    // responds to actual player events.
    if (_currentMediaItem?.id != item.id ||
        _currentMediaItem?.title != item.title ||
        _currentMediaItem?.artist != item.artist) {
      _currentMediaItem = item;
      mediaItem.add(item);
    }
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
    
    // Precache artwork for frequently accessed categories
    _precacheArtwork(provider);
  }

  /// Precache artwork for top items to improve loading performance
  Future<void> _precacheArtwork(MusicAssistantProvider provider) async {
    try {
      // Precache albums (top 50)
      final albums = SyncService.instance.cachedAlbums.take(50).toList();
      await _artworkCache.precacheCategory(provider, albums);
      
      // Precache artists (top 50)
      final artists = SyncService.instance.cachedArtists.take(50).toList();
      await _artworkCache.precacheCategory(provider, artists);
      
      _logger.log('AndroidAuto: Precached ${albums.length + artists.length} artworks');
    } catch (e) {
      _logger.log('AndroidAuto: Precache error (non-fatal): $e');
    }
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

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
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
        return _autoBuildFavorites(provider);

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
        // Load More pagination
        if (parentMediaId.startsWith('load_more|')) {
          return _autoBuildLoadMorePage(provider, parentMediaId);
        }
        // Home row content (home|recent-albums, etc.)
        if (parentMediaId.startsWith('home|')) {
          return _autoBuildHomeRowContent(provider, parentMediaId.substring(5));
        }
        return _autoBuildDynamicChildren(provider, parentMediaId);
    }
  }

  /// Handle "Load More" pagination
  Future<List<MediaItem>> _autoBuildLoadMorePage(
      MusicAssistantProvider provider, String mediaId) async {
    final parts = mediaId.split('|');
    if (parts.length < 3) return [];
    
    final category = parts[1]; // 'albums' or 'artists'
    final page = int.tryParse(parts[2]) ?? 0;
    
    if (category == 'albums') {
      final albums = SyncService.instance.cachedAlbums;
      final sortedAlbums = List<ma.Album>.from(albums)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      
      final start = page * _pageSize;
      final end = (start + _pageSize).clamp(0, sortedAlbums.length);
      
      final items = <MediaItem>[];
      for (int i = start; i < end; i++) {
        final album = sortedAlbums[i];
        items.add(MediaItem(
          id: 'album_actions|${album.provider}|${album.itemId}',  // CHANGED: point to actions menu
          title: album.name,
          artist: album.artistsString,
          artUri: _autoArtUriWithCache(provider, album),
          playable: false,
        ));
      }
      
      // Add another "Load More" if needed
      if (end < sortedAlbums.length) {
        items.add(MediaItem(
          id: 'load_more|albums|${page + 1}',
          title: 'Load More (${sortedAlbums.length - end} remaining)',
          playable: false,
        ));
      }
      
      return items;
    } else if (category == 'artists') {
      final artists = SyncService.instance.cachedArtists;
      final sortedArtists = List<ma.Artist>.from(artists)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      
      final start = page * _pageSize;
      final end = (start + _pageSize).clamp(0, sortedArtists.length);
      
      final items = <MediaItem>[];
      for (int i = start; i < end; i++) {
        final artist = sortedArtists[i];
        items.add(MediaItem(
          id: 'artist_actions|${artist.name}',  // CHANGED: point to actions menu
          title: artist.name,
          artUri: _autoArtUriWithCache(provider, artist),
          playable: false,
        ));
      }
      
      // Add another "Load More" if needed
      if (end < sortedArtists.length) {
        items.add(MediaItem(
          id: 'load_more|artists|${page + 1}',
          title: 'Load More (${sortedArtists.length - end} remaining)',
          playable: false,
        ));
      }
      
      return items;
    }
    
    return [];
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
      case 'artist_actions':  // NEW: Actions menu for artists
        final artistName = parts.sublist(1).join('|');
        return _autoBuildArtistActions(provider, artistName);
      case 'album_actions':  // NEW: Actions menu for albums
        if (parts.length >= 3) {
          return _autoBuildAlbumActions(provider, parts[1], parts[2]);
        }
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

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    final provider = _autoProvider;
    if (provider == null) {
      _logger.log('AndroidAuto: playFromMediaId called before provider is set');
      return;
    }

    final playerId = await SettingsService.getBuiltinPlayerId();
    if (playerId == null) {
      _logger.log('AndroidAuto: no builtin player ID — cannot play');
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

    try {
      // --- NEW: Handle Priority 4 Smart Playback Actions ---
      
      // Shuffle Playlist
      if (mediaId.startsWith('action_shuffle_playlist|')) {
        final parts = mediaId.split('|');
        if (parts.length >= 3) {
          await _playPlaylistShuffle(provider, playerId, parts[1], parts[2]);
        }
        return;
      }
      
      // Artist Radio
      if (mediaId.startsWith('action_radio_artist|')) {
        final artistName = mediaId.substring('action_radio_artist|'.length);
        await _playArtistRadio(provider, playerId, artistName);
        return;
      }
      
      // Artist Shuffle
      if (mediaId.startsWith('action_shuffle_artist|')) {
        final artistName = mediaId.substring('action_shuffle_artist|'.length);
        await _playArtistShuffle(provider, playerId, artistName);
        return;
      }
      
      // Play All Artist Tracks
      if (mediaId.startsWith('action_play_artist|')) {
        final artistName = mediaId.substring('action_play_artist|'.length);
        await _playArtistAll(provider, playerId, artistName);
        return;
      }
      
      // Album Radio
      if (mediaId.startsWith('action_radio_album|')) {
        final parts = mediaId.split('|');
        if (parts.length >= 3) {
          await _playAlbumRadio(provider, playerId, parts[1], parts[2]);
        }
        return;
      }
      
      // Album Shuffle
      if (mediaId.startsWith('action_shuffle_album|')) {
        final parts = mediaId.split('|');
        if (parts.length >= 3) {
          await _playAlbumShuffle(provider, playerId, parts[1], parts[2]);
        }
        return;
      }
      
      // Play Album Normally
      if (mediaId.startsWith('action_play_album|')) {
        final parts = mediaId.split('|');
        if (parts.length >= 3) {
          final album = SyncService.instance.cachedAlbums.firstWhere(
            (a) => a.provider == parts[1] && a.itemId == parts[2],
            orElse: () => throw Exception('Album not found'),
          );
          if (provider.api == null) await provider.checkAndReconnect();
          if (provider.api != null) {
            await provider.api!.playAlbum(playerId, album);
          }
        }
        return;
      }
      
      // --- Existing handlers ---
      
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
        await provider.playTracks(
          playerId,
          trackList,
          startIndex: index < 0 ? 0 : index,
        );
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
        // Format: podcast_ep|{provider}|{itemId}
        final parts = mediaId.split('|');
        if (parts.length < 3) return;
        if (provider.api == null) await provider.checkAndReconnect();
        if (provider.api == null) {
          _logger.log('AndroidAuto: no API, cannot play podcast');
          return;
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
        return;
      }
    } catch (e) {
      _logger.log('AndroidAuto: playFromMediaId error: $e');
    }
  }

  @override
  Future<List<MediaItem>> search(String query,
      [Map<String, dynamic>? extras]) async {
    final provider = _autoProvider;
    if (provider == null || query.trim().isEmpty) return [];

    try {
      final results = await provider.searchWithCache(query);
      final tracks = (results['tracks'] ?? []).whereType<ma.Track>().toList();
      const ctxKey = 'search||';
      _autoTrackCache[ctxKey] = tracks;
      return tracks
          .map((t) => _autoTrackItem(provider, t, ctxKey))
          .toList();
    } catch (e) {
      _logger.log('AndroidAuto: search error: $e');
      return [];
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
        )).toList();

      case 'discover-audiobooks':
        final books = await provider.getDiscoverAudiobooksWithCache();
        return books.map((b) => MediaItem(
          id: 'audiobook|${b.provider}|${b.itemId}',
          title: b.name, artist: b.authorsString,
          artUri: _autoArtUri(provider, b), playable: true,
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
        _autoTrackCache[ctxKey] = tracks;
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

  Future<List<MediaItem>> _autoBuildFavorites(
      MusicAssistantProvider provider) async {
    final tracks = await provider.getFavoriteTracks();
    _logger.log('AndroidAuto: Favorites returned ${tracks.length} tracks');
    const ctxKey = 'favs||';
    _autoTrackCache[ctxKey] = tracks;
    return tracks.map((t) => _autoTrackItem(provider, t, ctxKey)).toList();
  }

  List<MediaItem> _autoBuildPlaylistList(MusicAssistantProvider provider) {
    final playlists = SyncService.instance.cachedPlaylists;
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
    _autoTrackCache[ctxKey] = tracks;
    
    final items = <MediaItem>[];
    
    // Add shuffle option at the top if more than 1 track
    if (tracks.length > 1) {
      items.add(MediaItem(
        id: 'action_shuffle_playlist|$plProvider|$plItemId',
        title: '🔀 Shuffle Playlist',
        artist: 'Play ${tracks.length} tracks in random order',
        playable: true,
      ));
    }
    
    // Add normal track listings
    items.addAll(tracks.map((t) => _autoTrackItem(provider, t, ctxKey)));
    
    return items;
  }

  List<MediaItem> _autoBuildArtistList(MusicAssistantProvider provider) {
    final artists = SyncService.instance.cachedArtists;
    _logger.log('AndroidAuto: Artists: ${artists.length}');
    
    // Sort alphabetically
    final sortedArtists = List<ma.Artist>.from(artists)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    
    final items = <MediaItem>[];
    
    // If more than max items, paginate WITHOUT separators (to avoid confusion)
    if (sortedArtists.length > _maxItemsWithoutPagination) {
      // Add first page WITHOUT alphabetical separators (clearer in pagination mode)
      for (final artist in sortedArtists.take(_pageSize)) {
        items.add(MediaItem(
          id: 'artist_actions|${artist.name}',
          title: artist.name,
          artUri: _autoArtUriWithCache(provider, artist),
          playable: false,
        ));
      }
      
      // Add "Load More" button
      items.add(MediaItem(
        id: 'load_more|artists|1',
        title: 'Load More (${sortedArtists.length - _pageSize} remaining)',
        playable: false,
      ));
    } else {
      // Show all with separators if reasonable count
      items.addAll(_buildItemsWithSeparators(
        sortedArtists,
        provider,
        (artist) => MediaItem(
          id: 'artist_actions|${artist.name}',  // CHANGED: point to actions menu
          title: artist.name,
          artUri: _autoArtUriWithCache(provider, artist),
          playable: false,
        ),
        (artist) => artist.name,
      ));
    }
    
    return items;
  }

  Future<List<MediaItem>> _autoBuildArtistAlbums(
      MusicAssistantProvider provider, String artistName) async {
    var albums = await provider.getArtistAlbumsWithCache(artistName);
    if (albums.isEmpty) {
      // Fallback to library if API unavailable
      albums = provider.getArtistAlbumsFromLibrary(artistName);
    }
    _logger.log('AndroidAuto: Artist "$artistName" albums: ${albums.length}');
    return albums.map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}',
      title: a.name,
      artist: a.artistsString,
      artUri: _autoArtUri(provider, a),
      playable: false,
    )).toList();
  }

  /// Build actions menu for artist (Play All, Radio, Shuffle, Browse Albums)
  List<MediaItem> _autoBuildArtistActions(
      MusicAssistantProvider provider, String artistName) {
    _logger.log('AndroidAuto: Building artist actions for "$artistName"');
    
    // Find the artist for artwork
    final artist = SyncService.instance.cachedArtists
        .firstWhere((a) => a.name == artistName, orElse: () {
      // Fallback to mock artist with no artwork
      return ma.Artist(itemId: '', provider: '', name: artistName);
    });
    
    final artUri = _autoArtUri(provider, artist);
    
    return [
      // Option 1: Play Artist Radio
      MediaItem(
        id: 'action_radio_artist|$artistName',
        title: '\ud83d\udcfb Start Radio',
        artist: 'Play radio based on $artistName',
        artUri: artUri,
        playable: true,
      ),
      // Option 2: Shuffle Artist
      MediaItem(
        id: 'action_shuffle_artist|$artistName',
        title: '\ud83d\udd00 Shuffle Artist',
        artist: 'Play all tracks from $artistName in random order',
        artUri: artUri,
        playable: true,
      ),
      // Option 3: Play All
      MediaItem(
        id: 'action_play_artist|$artistName',
        title: '\u25b6\ufe0f Play All',
        artist: 'Play all tracks from $artistName',
        artUri: artUri,
        playable: true,
      ),
      // Option 4: Browse Albums (navigation)
      MediaItem(
        id: 'artist|$artistName',
        title: '\ud83d\udcbf View Albums',
        artist: 'Browse all albums by $artistName',
        artUri: artUri,
        playable: false,
      ),
    ];
  }

  /// Build actions menu for album (Play, Radio, Shuffle, View Tracks)
  List<MediaItem> _autoBuildAlbumActions(
      MusicAssistantProvider provider, String alProvider, String alItemId) {
    _logger.log('AndroidAuto: Building album actions for $alProvider/$alItemId');
    
    // Find the album for metadata
    final album = SyncService.instance.cachedAlbums.firstWhere(
      (a) => a.provider == alProvider && a.itemId == alItemId,
      orElse: () {
        // Fallback to mock album
        return ma.Album(itemId: alItemId, provider: alProvider, name: 'Album');
      },
    );
    
    final artUri = _autoArtUri(provider, album);
    
    return [
      // Option 1: Play Album
      MediaItem(
        id: 'action_play_album|$alProvider|$alItemId',
        title: '\u25b6\ufe0f Play Album',
        artist: 'Play ${album.name}',
        artUri: artUri,
        playable: true,
      ),
      // Option 2: Radio based on Album
      MediaItem(
        id: 'action_radio_album|$alProvider|$alItemId',
        title: '\ud83d\udcfb Start Radio',
        artist: 'Play radio based on ${album.name}',
        artUri: artUri,
        playable: true,
      ),
      // Option 3: Shuffle Album
      MediaItem(
        id: 'action_shuffle_album|$alProvider|$alItemId',
        title: '\ud83d\udd00 Shuffle Album',
        artist: 'Shuffle ${album.name}',
        artUri: artUri,
        playable: true,
      ),
      // Option 4: View Tracks (navigation)
      MediaItem(
        id: 'album|$alProvider|$alItemId',
        title: '\ud83c\udfb5 View Tracks',
        artist: 'Browse all tracks in ${album.name}',
        artUri: artUri,
        playable: false,
      ),
    ];
  }

  List<MediaItem> _autoBuildAlbumList(MusicAssistantProvider provider) {
    final albums = SyncService.instance.cachedAlbums;
    _logger.log('AndroidAuto: Albums: ${albums.length}');
    
    // Sort alphabetically
    final sortedAlbums = List<ma.Album>.from(albums)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    
    final items = <MediaItem>[];
    
    // If more than max items, paginate WITHOUT separators (to avoid confusion)
    if (sortedAlbums.length > _maxItemsWithoutPagination) {
      // Add first page WITHOUT alphabetical separators (clearer in pagination mode)
      for (final album in sortedAlbums.take(_pageSize)) {
        items.add(MediaItem(
          id: 'album_actions|${album.provider}|${album.itemId}',
          title: album.name,
          artist: album.artistsString,
          artUri: _autoArtUriWithCache(provider, album),
          playable: false,
        ));
      }
      
      // Add "Load More" button
      items.add(MediaItem(
        id: 'load_more|albums|1',
        title: 'Load More (${sortedAlbums.length - _pageSize} remaining)',
        playable: false,
      ));
    } else {
      // Show all with separators if reasonable count
      items.addAll(_buildItemsWithSeparators(
        sortedAlbums,
        provider,
        (album) => MediaItem(
          id: 'album_actions|${album.provider}|${album.itemId}',  // CHANGED: point to actions menu
          title: album.name,
          artist: album.artistsString,
          artUri: _autoArtUriWithCache(provider, album),
          playable: false,
        ),
        (album) => album.name,
      ));
    }
    
    return items;
  }

  Future<List<MediaItem>> _autoBuildAlbumTracks(
      MusicAssistantProvider provider, String alProvider, String alItemId) async {
    final tracks =
        await provider.getAlbumTracksWithCache(alProvider, alItemId);
    _logger.log('AndroidAuto: Album $alProvider/$alItemId tracks: ${tracks.length}');
    final ctxKey = 'album|$alProvider|$alItemId';
    _autoTrackCache[ctxKey] = tracks;
    return tracks.map((t) => _autoTrackItem(provider, t, ctxKey)).toList();
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
    return episodes.map((e) => MediaItem(
      id: 'podcast_ep|${e.provider}|${e.itemId}',
      title: e.name,
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

  MediaItem _autoTrackItem(
      MusicAssistantProvider provider, ma.Track t, String ctxKey) {
    return MediaItem(
      id: 'track|${t.provider}|${t.itemId}|$ctxKey',
      title: t.name,
      artist: t.artistsString,
      album: t.album?.name,
      duration: t.duration,
      artUri: _autoArtUri(provider, t),
      playable: true,
    );
  }

  Uri? _autoArtUri(MusicAssistantProvider provider, ma.MediaItem item) {
    final url = provider.getImageUrl(item, size: 256);
    return url != null ? Uri.tryParse(url) : null;
  }

  /// Get artwork URI with caching support
  Uri? _autoArtUriWithCache(MusicAssistantProvider provider, ma.MediaItem item) {
    // Try cache first
    final cached = _artworkCache.getCached(item.provider, item.itemId);
    if (cached != null) return cached;
    
    // Fallback to generating URL
    return _autoArtUri(provider, item);
  }

  /// Build list with alphabetical separators
  List<MediaItem> _buildItemsWithSeparators<T extends ma.MediaItem>(
    List<T> items,
    MusicAssistantProvider provider,
    MediaItem Function(T) itemBuilder,
    String Function(T) nameExtractor,
  ) {
    final result = <MediaItem>[];
    String? lastLetter;
    
    for (final item in items) {
      final name = nameExtractor(item);
      if (name.isEmpty) continue;
      
      final firstChar = name[0].toUpperCase();
      // Only add separator for letters/numbers
      if (RegExp(r'[A-Z0-9]').hasMatch(firstChar) && firstChar != lastLetter) {
        result.add(MediaItem(
          id: 'separator|$firstChar',
          title: '─── $firstChar ───',
          playable: false,
        ));
        lastLetter = firstChar;
      }
      
      result.add(itemBuilder(item));
    }
    
    return result;
  }

  // --- Priority 4: Smart Playback Helper Functions ---

  /// Play artist radio (similar tracks based on artist)
  Future<void> _playArtistRadio(
      MusicAssistantProvider provider, String playerId, String artistName) async {
    _logger.log('AndroidAuto: Playing artist radio for "$artistName"');
    
    try {
      // Find the artist
      final artist = SyncService.instance.cachedArtists.firstWhere(
        (a) => a.name == artistName,
        orElse: () => throw Exception('Artist not found: $artistName'),
      );
      
      // Ensure we have API connection
      if (provider.api == null) await provider.checkAndReconnect();
      if (provider.api == null) {
        _logger.log('AndroidAuto: No API, cannot play artist radio');
        return;
      }
      
      // Use the API's playArtistRadio method
      await provider.api!.playArtistRadio(playerId, artist);
    } catch (e) {
      _logger.log('AndroidAuto: Error playing artist radio: $e');
    }
  }

  /// Shuffle all tracks from an artist
  Future<void> _playArtistShuffle(
      MusicAssistantProvider provider, String playerId, String artistName) async {
    _logger.log('AndroidAuto: Shuffling artist "$artistName"');
    
    try {
      // Get all albums from artist
      final albums = await provider.getArtistAlbumsWithCache(artistName);
      if (albums.isEmpty) {
        _logger.log('AndroidAuto: No albums found for artist "$artistName"');
        return;
      }
      
      // Collect all tracks (limit to 10 albums to avoid timeout)
      final allTracks = <ma.Track>[];
      for (final album in albums.take(10)) {
        final tracks = await provider.getAlbumTracksWithCache(
          album.provider,
          album.itemId,
        );
        allTracks.addAll(tracks);
      }
      
      if (allTracks.isEmpty) {
        _logger.log('AndroidAuto: No tracks found for artist "$artistName"');
        return;
      }
      
      // Shuffle the tracks
      allTracks.shuffle();
      
      // Play with shuffle enabled
      await provider.playTracks(playerId, allTracks);
      await provider.toggleShuffle(playerId, true);
      
      _logger.log('AndroidAuto: Playing ${allTracks.length} shuffled tracks from "$artistName"');
    } catch (e) {
      _logger.log('AndroidAuto: Error shuffling artist: $e');
    }
  }

  /// Play all tracks from an artist (chronological order by album year)
  Future<void> _playArtistAll(
      MusicAssistantProvider provider, String playerId, String artistName) async {
    _logger.log('AndroidAuto: Playing all tracks from "$artistName"');
    
    try {
      // Get all albums from artist
      final albums = await provider.getArtistAlbumsWithCache(artistName);
      if (albums.isEmpty) {
        _logger.log('AndroidAuto: No albums found for artist "$artistName"');
        return;
      }
      
      // Sort by year (most recent first)
      albums.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
      
      // Collect all tracks
      final allTracks = <ma.Track>[];
      for (final album in albums) {
        final tracks = await provider.getAlbumTracksWithCache(
          album.provider,
          album.itemId,
        );
        allTracks.addAll(tracks);
      }
      
      if (allTracks.isEmpty) {
        _logger.log('AndroidAuto: No tracks found for artist "$artistName"');
        return;
      }
      
      await provider.playTracks(playerId, allTracks);
      
      _logger.log('AndroidAuto: Playing ${allTracks.length} tracks from "$artistName"');
    } catch (e) {
      _logger.log('AndroidAuto: Error playing artist: $e');
    }
  }

  /// Play radio based on an album (similar tracks)
  Future<void> _playAlbumRadio(
      MusicAssistantProvider provider, String playerId,
      String alProvider, String alItemId) async {
    _logger.log('AndroidAuto: Playing album radio for $alProvider/$alItemId');
    
    try {
      final tracks = await provider.getAlbumTracksWithCache(alProvider, alItemId);
      if (tracks.isEmpty) {
        _logger.log('AndroidAuto: No tracks found in album');
        return;
      }
      
      // Start radio based on first track
      await provider.playRadio(playerId, tracks.first);
      
      _logger.log('AndroidAuto: Started radio from album');
    } catch (e) {
      _logger.log('AndroidAuto: Error playing album radio: $e');
    }
  }

  /// Shuffle album tracks
  Future<void> _playAlbumShuffle(
      MusicAssistantProvider provider, String playerId,
      String alProvider, String alItemId) async {
    _logger.log('AndroidAuto: Shuffling album $alProvider/$alItemId');
    
    try {
      final tracks = await provider.getAlbumTracksWithCache(alProvider, alItemId);
      if (tracks.isEmpty) {
        _logger.log('AndroidAuto: No tracks found in album');
        return;
      }
      
      // Shuffle the tracks
      final shuffled = List<ma.Track>.from(tracks)..shuffle();
      
      // Play with shuffle enabled
      await provider.playTracks(playerId, shuffled);
      await provider.toggleShuffle(playerId, true);
      
      _logger.log('AndroidAuto: Playing ${shuffled.length} shuffled tracks from album');
    } catch (e) {
      _logger.log('AndroidAuto: Error shuffling album: $e');
    }
  }

  /// Shuffle playlist tracks
  Future<void> _playPlaylistShuffle(
      MusicAssistantProvider provider, String playerId,
      String plProvider, String plItemId) async {
    _logger.log('AndroidAuto: Shuffling playlist $plProvider/$plItemId');
    
    try {
      final ctxKey = 'plist|$plProvider|$plItemId';
      final tracks = _autoTrackCache[ctxKey];
      
      if (tracks == null || tracks.isEmpty) {
        // Cache miss - fetch tracks
        final fetchedTracks = await provider.getPlaylistTracksWithCache(plProvider, plItemId);
        if (fetchedTracks.isEmpty) {
          _logger.log('AndroidAuto: No tracks found in playlist');
          return;
        }
        
        // Shuffle and play
        final shuffled = List<ma.Track>.from(fetchedTracks)..shuffle();
        await provider.playTracks(playerId, shuffled);
        await provider.toggleShuffle(playerId, true);
        
        _logger.log('AndroidAuto: Playing ${shuffled.length} shuffled tracks from playlist');
      } else {
        // Use cached tracks
        final shuffled = List<ma.Track>.from(tracks)..shuffle();
        await provider.playTracks(playerId, shuffled);
        await provider.toggleShuffle(playerId, true);
        
        _logger.log('AndroidAuto: Playing ${shuffled.length} shuffled tracks from playlist (cached)');
      }
    } catch (e) {
      _logger.log('AndroidAuto: Error shuffling playlist: $e');
    }
  }

  // ---------------------------------------------------------------------------

  /// Dispose of resources and cancel all subscriptions
  Future<void> dispose() async {
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _playbackEventSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    await _player.dispose();
  }
}
