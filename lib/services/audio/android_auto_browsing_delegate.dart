import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import '../debug_logger.dart';
import '../settings_service.dart';
import '../sync_service.dart';
import '../../providers/music_assistant_provider.dart';
import '../../models/media_item.dart' as ma;

/// Handles all Android Auto media-browsing logic (category trees, item builders,
/// artwork resolution, A-Z indexing).
///
/// Extracted from [MassivAudioHandler] to keep the audio handler focused on
/// playback control and notification management.
///
/// The delegate is stateless except for the shared track cache, which is
/// passed in by reference from the handler so that [playFromMediaId] can still
/// look up queued tracks after browsing.
class AndroidAutoBrowsingDelegate {
  final DebugLogger _logger;

  /// Shared track cache: maps context key → ordered track list.
  /// Owned by [MassivAudioHandler]; passed by reference so mutations are
  /// visible from [playFromMediaId].
  final Map<String, List<ma.Track>> trackCache;

  AndroidAutoBrowsingDelegate({
    required DebugLogger logger,
    required this.trackCache,
  }) : _logger = logger;

  // ---------------------------------------------------------------------------
  // Media ID constants — root categories
  // ---------------------------------------------------------------------------

  static const autoIdHome = 'cat|home';
  static const autoIdMusic = 'cat|music';
  static const autoIdAudiobooks = 'cat|audiobooks';
  static const autoIdPodcasts = 'cat|podcasts';
  static const autoIdRadio = 'cat|radio';

  // Music subcategories
  static const autoIdPlaylists = 'cat|playlists';
  static const autoIdArtists = 'cat|artists';
  static const autoIdAlbums = 'cat|albums';
  static const autoIdFavorites = 'cat|favorites';

  // Favourite subcategories
  static const autoIdFavArtists = 'cat|fav_artists';
  static const autoIdFavAlbums = 'cat|fav_albums';
  static const autoIdFavTracks = 'cat|fav_tracks';

  // Audiobook subcategories
  static const autoIdAbAuthors = 'cat|ab_authors';
  static const autoIdAbBooks = 'cat|ab_books';
  static const autoIdAbSeries = 'cat|ab_series';

  // Use an A-Z index for large lists to keep Android Auto browsing fast.
  static const alphaIndexThreshold = 180;

  // ---------------------------------------------------------------------------
  // Content style hints & icon URIs
  // ---------------------------------------------------------------------------

  static const gridHints = {
    'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2,
    'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 2,
  };

  static const _iconPkg = 'com.collotsspot.ensemble';
  static final iconHome     = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_home');
  static final iconMusic    = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_music');
  static final iconBook     = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_book');
  static final iconPodcast  = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_podcast');
  static final iconRadio    = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_radio');
  static final iconArtist   = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_artist');
  static final iconAlbum    = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_album');
  static final iconPlaylist = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_playlist');
  static final iconFavorite = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_favorite');
  static final iconStartRadio = Uri.parse('android.resource://$_iconPkg/drawable/ic_auto_radio');

  // ---------------------------------------------------------------------------
  // Artwork
  // ---------------------------------------------------------------------------

  static const _artworkAuthority = 'com.collotsspot.ensemble.artwork';

  Uri? artUri(MusicAssistantProvider provider, ma.MediaItem item) {
    final url = provider.getImageUrl(item, size: 256);
    if (url == null) return null;
    return _contentUriForArtwork(url);
  }

  static Uri? _contentUriForArtwork(String httpUrl) {
    final encoded = base64Url.encode(const Utf8Encoder().convert(httpUrl));
    return Uri.tryParse('content://$_artworkAuthority/$encoded');
  }

  // ---------------------------------------------------------------------------
  // Track cache helpers
  // ---------------------------------------------------------------------------

  static const _maxTrackCacheEntries = 50;

  void cacheTrackList(String key, List<ma.Track> tracks) {
    // Remove first so re-inserting an existing key refreshes its LRU position.
    trackCache.remove(key);
    trackCache[key] = tracks;
    while (trackCache.length > _maxTrackCacheEntries) {
      trackCache.remove(trackCache.keys.first);
    }
  }

  // ---------------------------------------------------------------------------
  // Root & category builders
  // ---------------------------------------------------------------------------

  List<MediaItem> buildRoot() {
    return [
      MediaItem(id: autoIdHome, title: 'Home', playable: false, artUri: iconHome),
      MediaItem(id: autoIdMusic, title: 'Music', playable: false, artUri: iconMusic),
      MediaItem(id: autoIdAudiobooks, title: 'Audiobooks', playable: false, artUri: iconBook),
      MediaItem(id: autoIdPodcasts, title: 'Podcasts', playable: false, artUri: iconPodcast, extras: gridHints),
      MediaItem(id: autoIdRadio, title: 'Radio', playable: false, artUri: iconRadio, extras: gridHints),
    ];
  }

  List<MediaItem> buildMusicCategories() {
    return [
      MediaItem(id: autoIdArtists, title: 'Artists', playable: false, artUri: iconArtist, extras: gridHints),
      MediaItem(id: autoIdAlbums, title: 'Albums', playable: false, artUri: iconAlbum, extras: gridHints),
      MediaItem(id: autoIdPlaylists, title: 'Playlists', playable: false, artUri: iconPlaylist, extras: gridHints),
      MediaItem(id: autoIdFavorites, title: 'Favourites', playable: false, artUri: iconFavorite),
    ];
  }

  List<MediaItem> buildAudiobookCategories() {
    return [
      MediaItem(id: autoIdAbAuthors, title: 'Authors', playable: false, artUri: iconArtist),
      MediaItem(id: autoIdAbBooks, title: 'Books', playable: false, artUri: iconBook, extras: gridHints),
      MediaItem(id: autoIdAbSeries, title: 'Series', playable: false, artUri: iconBook, extras: gridHints),
    ];
  }

  List<MediaItem> buildFavoriteCategories() {
    return [
      MediaItem(id: autoIdFavArtists, title: 'Favourite Artists', playable: false, artUri: iconArtist),
      MediaItem(id: autoIdFavAlbums, title: 'Favourite Albums', playable: false, artUri: iconAlbum, extras: gridHints),
      MediaItem(id: autoIdFavTracks, title: 'Favourite Tracks', playable: false, artUri: iconFavorite),
    ];
  }

  // ---------------------------------------------------------------------------
  // Home builders
  // ---------------------------------------------------------------------------

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

  Future<List<MediaItem>> buildHome() async {
    final rowOrder = await SettingsService.getHomeRowOrder();
    final items = <MediaItem>[];
    for (final rowId in rowOrder) {
      if (!await _isHomeRowEnabled(rowId)) continue;
      final title = _homeRowTitles[rowId];
      if (title == null) continue;
      items.add(MediaItem(id: 'home|$rowId', title: title, playable: false, extras: gridHints));
    }
    _logger.log('AndroidAuto: Home built ${items.length} rows');
    return items;
  }

  Future<bool> _isHomeRowEnabled(String rowId) async {
    switch (rowId) {
      case 'recent-albums':           return SettingsService.getShowRecentAlbums();
      case 'discover-artists':        return SettingsService.getShowDiscoverArtists();
      case 'discover-albums':         return SettingsService.getShowDiscoverAlbums();
      case 'continue-listening':      return SettingsService.getShowContinueListeningAudiobooks();
      case 'discover-audiobooks':     return SettingsService.getShowDiscoverAudiobooks();
      case 'discover-series':         return SettingsService.getShowDiscoverSeries();
      case 'favorite-albums':         return SettingsService.getShowFavoriteAlbums();
      case 'favorite-artists':        return SettingsService.getShowFavoriteArtists();
      case 'favorite-tracks':         return SettingsService.getShowFavoriteTracks();
      case 'favorite-playlists':      return SettingsService.getShowFavoritePlaylists();
      case 'favorite-radio-stations': return SettingsService.getShowFavoriteRadioStations();
      case 'favorite-podcasts':       return SettingsService.getShowFavoritePodcasts();
      default: return false;
    }
  }

  Future<List<MediaItem>> buildHomeRowContent(
      MusicAssistantProvider provider, String rowId) async {
    switch (rowId) {
      case 'recent-albums':
        var albums = await provider.getRecentAlbumsWithCache();
        if (albums.isEmpty) albums = SyncService.instance.cachedAlbums.take(20).toList();
        return albums.take(20).map((a) => MediaItem(
          id: 'album|${a.provider}|${a.itemId}',
          title: a.name, artist: a.artistsString,
          artUri: artUri(provider, a), playable: false,
        )).toList();

      case 'discover-artists':
        var artists = await provider.getDiscoverArtistsWithCache();
        if (artists.isEmpty) artists = SyncService.instance.cachedArtists.take(10).toList();
        return artists.take(10).map((a) => MediaItem(
          id: 'artist|${a.name}', title: a.name,
          artUri: artUri(provider, a), playable: false,
        )).toList();

      case 'discover-albums':
        final albums = await provider.getDiscoverAlbumsWithCache();
        return albums.take(20).map((a) => MediaItem(
          id: 'album|${a.provider}|${a.itemId}',
          title: a.name, artist: a.artistsString,
          artUri: artUri(provider, a), playable: false,
        )).toList();

      case 'continue-listening':
        final books = await provider.getInProgressAudiobooksWithCache();
        return books.map((b) => MediaItem(
          id: 'audiobook|${b.provider}|${b.itemId}',
          title: b.name, artist: b.authorsString,
          artUri: artUri(provider, b), playable: true,
          extras: audiobookExtras(b),
        )).toList();

      case 'discover-audiobooks':
        final books = await provider.getDiscoverAudiobooksWithCache();
        return books.map((b) => MediaItem(
          id: 'audiobook|${b.provider}|${b.itemId}',
          title: b.name, artist: b.authorsString,
          artUri: artUri(provider, b), playable: true,
          extras: audiobookExtras(b),
        )).toList();

      case 'discover-series':
        return buildAudiobookSeriesList(provider);

      case 'favorite-albums':
        final albums = await provider.getFavoriteAlbums();
        return albums.map((a) => MediaItem(
          id: 'album|${a.provider}|${a.itemId}',
          title: a.name, artist: a.artistsString,
          artUri: artUri(provider, a), playable: false,
        )).toList();

      case 'favorite-artists':
        final artists = await provider.getFavoriteArtists();
        return artists.map((a) => MediaItem(
          id: 'artist|${a.name}', title: a.name,
          artUri: artUri(provider, a), playable: false,
        )).toList();

      case 'favorite-tracks':
        final tracks = await provider.getFavoriteTracks();
        const ctxKey = 'favs||';
        cacheTrackList(ctxKey, tracks);
        return tracks.map((t) => trackItem(provider, t, ctxKey)).toList();

      case 'favorite-playlists':
        final playlists = await provider.getFavoritePlaylists();
        return playlists.map((p) => MediaItem(
          id: 'playlist|${p.provider}|${p.itemId}',
          title: p.name, artist: p.owner,
          artUri: artUri(provider, p), playable: false,
        )).toList();

      case 'favorite-radio-stations':
        final stations = await provider.getFavoriteRadioStations();
        return stations.map((s) => MediaItem(
          id: 'radio|${s.provider}|${s.itemId}',
          title: s.name, artUri: artUri(provider, s), playable: true,
        )).toList();

      case 'favorite-podcasts':
        final podcasts = SyncService.instance.cachedPodcasts
            .where((p) => p.favorite == true).toList();
        return podcasts.map((p) => MediaItem(
          id: 'podcast|${p.provider}|${p.itemId}',
          title: p.name, artUri: artUri(provider, p), playable: false,
        )).toList();

      default:
        return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Music builders
  // ---------------------------------------------------------------------------

  Future<List<MediaItem>> buildFavArtists(MusicAssistantProvider provider) async {
    final artists = await provider.getFavoriteArtists();
    return artists.map((a) => MediaItem(
      id: 'artist|${a.name}', title: a.name,
      artUri: artUri(provider, a), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> buildFavAlbums(MusicAssistantProvider provider) async {
    final albums = await provider.getFavoriteAlbums();
    return albums.map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}', title: a.name, artist: a.artistsString,
      artUri: artUri(provider, a), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> buildFavTracks(MusicAssistantProvider provider) async {
    final tracks = await provider.getFavoriteTracks();
    _logger.log('AndroidAuto: Fav tracks returned ${tracks.length} tracks');
    const ctxKey = 'favs||';
    cacheTrackList(ctxKey, tracks);
    return buildTrackItems(provider, tracks, ctxKey);
  }

  Future<List<MediaItem>> buildPlaylistList(MusicAssistantProvider provider) async {
    var playlists = SyncService.instance.cachedPlaylists;
    if (playlists.isEmpty) {
      _logger.log('AndroidAuto: cachedPlaylists empty, loading from cache');
      await SyncService.instance.loadFromCache();
      playlists = SyncService.instance.cachedPlaylists;
    }
    _logger.log('AndroidAuto: Playlists: ${playlists.length}');
    return playlists.map((p) => MediaItem(
      id: 'playlist|${p.provider}|${p.itemId}',
      title: p.name, artist: p.owner,
      artUri: artUri(provider, p), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> buildPlaylistTracks(
      MusicAssistantProvider provider, String plProvider, String plItemId) async {
    final tracks = await provider.getPlaylistTracksWithCache(plProvider, plItemId);
    final ctxKey = 'plist|$plProvider|$plItemId';
    cacheTrackList(ctxKey, tracks);
    return buildTrackItems(provider, tracks, ctxKey);
  }

  Future<List<MediaItem>> buildArtistList(
    MusicAssistantProvider provider, {
    String? alphaFilter,
  }) async {
    var artists = SyncService.instance.cachedArtists;
    if (artists.isEmpty) {
      _logger.log('AndroidAuto: cachedArtists empty, loading from cache');
      await SyncService.instance.loadFromCache();
      artists = SyncService.instance.cachedArtists;
    }
    artists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (alphaFilter == null && artists.length > alphaIndexThreshold) {
      _logger.log('AndroidAuto: Artists large list (${artists.length}), returning A-Z index');
      return buildAlphaIndexItems(
        items: artists.map((a) => a.name), idPrefix: 'artists_alpha', icon: iconArtist);
    }

    final filtered = alphaFilter == null
        ? artists
        : artists.where((a) => alphaKey(a.name) == alphaFilter).toList();
    _logger.log('AndroidAuto: Artists: ${filtered.length}${alphaFilter != null ? ' (filter $alphaFilter)' : ''}');
    return filtered.map((a) => MediaItem(
      id: 'artist|${a.name}', title: a.name,
      artUri: artUri(provider, a), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> buildArtistAlbums(
      MusicAssistantProvider provider, String artistName) async {
    var albums = await provider.getArtistAlbumsWithCache(artistName);
    if (albums.isEmpty) albums = provider.getArtistAlbumsFromLibrary(artistName);
    _logger.log('AndroidAuto: Artist "$artistName" albums: ${albums.length}');
    return [
      MediaItem(id: 'artistradio|$artistName', title: 'Start Radio', artUri: iconRadio, playable: true),
      ...albums.map((a) => MediaItem(
        id: 'album|${a.provider}|${a.itemId}',
        title: a.name, artist: a.artistsString,
        artUri: artUri(provider, a), playable: false,
      )),
    ];
  }

  Future<List<MediaItem>> buildAlbumList(
    MusicAssistantProvider provider, {
    String? alphaFilter,
  }) async {
    var albums = SyncService.instance.cachedAlbums;
    if (albums.isEmpty) {
      _logger.log('AndroidAuto: cachedAlbums empty, loading from cache');
      await SyncService.instance.loadFromCache();
      albums = SyncService.instance.cachedAlbums;
    }
    albums.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (alphaFilter == null && albums.length > alphaIndexThreshold) {
      _logger.log('AndroidAuto: Albums large list (${albums.length}), returning A-Z index');
      return buildAlphaIndexItems(
        items: albums.map((a) => a.name), idPrefix: 'albums_alpha', icon: iconAlbum);
    }

    final filtered = alphaFilter == null
        ? albums
        : albums.where((a) => alphaKey(a.name) == alphaFilter).toList();
    _logger.log('AndroidAuto: Albums: ${filtered.length}${alphaFilter != null ? ' (filter $alphaFilter)' : ''}');
    return filtered.map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}',
      title: a.name, artist: a.artistsString,
      artUri: artUri(provider, a), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> buildAlbumTracks(
      MusicAssistantProvider provider, String alProvider, String alItemId) async {
    final tracks = await provider.getAlbumTracksWithCache(alProvider, alItemId);
    _logger.log('AndroidAuto: Album $alProvider/$alItemId tracks: ${tracks.length}');
    final ctxKey = 'album|$alProvider|$alItemId';
    cacheTrackList(ctxKey, tracks);
    return buildTrackItems(provider, tracks, ctxKey);
  }

  List<MediaItem> buildTrackItems(
    MusicAssistantProvider provider,
    List<ma.Track> tracks,
    String ctxKey, {
    String? alphaFilter,
  }) {
    final sorted = List<ma.Track>.from(tracks)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (alphaFilter == null && sorted.length > alphaIndexThreshold) {
      _logger.log('AndroidAuto: Tracks large list (${sorted.length}) for $ctxKey, returning A-Z index');
      return buildAlphaIndexItems(
        items: sorted.map((t) => t.name),
        idPrefix: 'tracks_alpha|${Uri.encodeComponent(ctxKey)}',
        icon: iconMusic,
      );
    }

    final filtered = alphaFilter == null
        ? sorted
        : sorted.where((t) => alphaKey(t.name) == alphaFilter).toList();
    final items = filtered.map((t) => trackItem(provider, t, ctxKey)).toList();
    if (items.isNotEmpty) {
      items.insert(0, startRadioItem(ctxKey));
    }
    return items;
  }

  List<MediaItem> buildAlphaIndexItems({
    required Iterable<String> items,
    required String idPrefix,
    required Uri icon,
  }) {
    final counts = <String, int>{};
    for (final value in items) {
      final key = alphaKey(value);
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final keys = counts.keys.toList()
      ..sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        return a.compareTo(b);
      });

    return keys.map((key) => MediaItem(
      id: '$idPrefix|$key',
      title: '$key (${counts[key]})',
      artUri: icon,
      playable: false,
    )).toList();
  }

  String alphaKey(String input) {
    final trimmed = input.trimLeft();
    if (trimmed.isEmpty) return '#';

    var c = trimmed[0].toUpperCase();
    const fold = {
      'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A',
      'Ç': 'C',
      'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E',
      'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I',
      'Ñ': 'N',
      'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O',
      'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U',
      'Ý': 'Y',
    };
    c = fold[c] ?? c;
    if (RegExp(r'^[A-Z]$').hasMatch(c)) return c;
    return '#';
  }

  // ---------------------------------------------------------------------------
  // Audiobook builders
  // ---------------------------------------------------------------------------

  List<MediaItem> buildAudiobookAuthorList(MusicAssistantProvider provider) {
    final books = SyncService.instance.cachedAudiobooks;

    // Group books by author and pick the most recent one as the folder artwork.
    final authorBestBook = <String, ma.Audiobook>{};
    for (final b in books) {
      final author = b.authorsString;
      final existing = authorBestBook[author];
      if (existing == null ||
          (b.year ?? 0) > (existing.year ?? 0)) {
        authorBestBook[author] = b;
      }
    }

    // Preserve insertion order (first encountered) for display.
    final seen = <String>{};
    final items = <MediaItem>[];
    for (final b in books) {
      final author = b.authorsString;
      if (seen.add(author)) {
        final bestBook = authorBestBook[author]!;
        items.add(MediaItem(
          id: 'ab_author|$author',
          title: author,
          artUri: artUri(provider, bestBook),
          playable: false,
        ));
      }
    }
    _logger.log('AndroidAuto: Audiobook authors: ${items.length}');
    return items;
  }

  List<MediaItem> buildAuthorAudiobooks(
      MusicAssistantProvider provider, String authorName) {
    final books = SyncService.instance.cachedAudiobooks
        .where((b) => b.authorsString == authorName)
        .toList();
    return books.map((b) => MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: b.name, artist: b.authorsString,
      artUri: artUri(provider, b), playable: true,
      extras: audiobookExtras(b),
    )).toList();
  }

  Future<List<MediaItem>> buildAudiobookList(MusicAssistantProvider provider) async {
    var books = SyncService.instance.cachedAudiobooks;
    if (books.isEmpty) {
      _logger.log('AndroidAuto: cachedAudiobooks empty, loading from cache');
      await SyncService.instance.loadFromCache();
      books = SyncService.instance.cachedAudiobooks;
    }
    _logger.log('AndroidAuto: Books: ${books.length}');
    books.sort((a, b) => a.name.compareTo(b.name));
    return books.take(500).map((b) => MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: b.name, artist: b.authorsString,
      artUri: artUri(provider, b), playable: true,
      extras: audiobookExtras(b),
    )).toList();
  }

  Future<List<MediaItem>> buildAudiobookSeriesList(
      MusicAssistantProvider provider) async {
    final series = await provider.getDiscoverSeriesWithCache();
    _logger.log('AndroidAuto: Audiobook series: ${series.length}');
    final items = <MediaItem>[];
    for (final s in series) {
      Uri? art;
      var cachedBooks = provider.getCachedSeriesAudiobooks(s.id);
      if (cachedBooks == null || cachedBooks.isEmpty) {
        try {
          cachedBooks = await provider.getSeriesAudiobooksWithCache(s.id);
        } catch (_) {}
      }
      if (cachedBooks != null && cachedBooks.isNotEmpty) {
        art = artUri(provider, cachedBooks.first);
      }
      items.add(MediaItem(id: 'ab_series|${s.id}', title: s.name, artUri: art, playable: false));
    }
    return items;
  }

  Future<List<MediaItem>> buildSeriesAudiobooks(
      MusicAssistantProvider provider, String seriesPath) async {
    final books = await provider.getSeriesAudiobooksWithCache(seriesPath);
    return books.map((b) => MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: b.name, artist: b.authorsString,
      artUri: artUri(provider, b), playable: true,
      extras: audiobookExtras(b),
    )).toList();
  }

  // ---------------------------------------------------------------------------
  // Podcast builders
  // ---------------------------------------------------------------------------

  List<MediaItem> buildPodcastList(MusicAssistantProvider provider) {
    final podcasts = SyncService.instance.cachedPodcasts;
    _logger.log('AndroidAuto: Podcasts: ${podcasts.length}');
    return podcasts.map((p) => MediaItem(
      id: 'podcast|${p.provider}|${p.itemId}',
      title: p.name, artUri: artUri(provider, p), playable: false,
    )).toList();
  }

  Future<List<MediaItem>> buildPodcastEpisodes(
      MusicAssistantProvider provider, String podProvider, String podItemId) async {
    final episodes = await provider.getPodcastEpisodesWithCache(
      podItemId, provider: podProvider);
    final podcast = SyncService.instance.cachedPodcasts
        .where((p) => p.itemId == podItemId && p.provider == podProvider)
        .firstOrNull;
    return episodes.map((e) => MediaItem(
      id: 'podcast_ep|${e.provider}|${e.itemId}|$podProvider|$podItemId',
      title: e.name, artist: podcast?.name,
      duration: e.duration, artUri: artUri(provider, e), playable: true,
    )).toList();
  }

  // ---------------------------------------------------------------------------
  // Radio builder
  // ---------------------------------------------------------------------------

  Future<List<MediaItem>> buildRadioList(MusicAssistantProvider provider) async {
    if (provider.radioStations.isEmpty) {
      _logger.log('AndroidAuto: Radio empty, loading stations');
      await provider.loadRadioStations();
    }
    final stations = provider.radioStations;
    _logger.log('AndroidAuto: Radio stations: ${stations.length}');
    return stations.map((s) => MediaItem(
      id: 'radio|${s.provider}|${s.itemId}',
      title: s.name, artUri: artUri(provider, s), playable: true,
    )).toList();
  }

  // ---------------------------------------------------------------------------
  // Item helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic>? audiobookExtras(ma.Audiobook book) {
    if (book.progress <= 0 && book.fullyPlayed != true) return null;
    return {
      'android.media.extra.PLAYBACK_STATUS': book.fullyPlayed == true ? 2 : 1,
      'android.media.extra.PLAYBACK_STATUS_COMPLETION_PERCENTAGE': book.progress,
    };
  }

  MediaItem startRadioItem(String ctxKey) {
    return MediaItem(
      id: 'smartshuffle|$ctxKey', title: 'Start Radio',
      artUri: iconStartRadio, playable: true);
  }

  MediaItem trackItem(MusicAssistantProvider provider, ma.Track t, String ctxKey) {
    final firstArtist = t.artists?.isNotEmpty == true ? t.artists!.first.name : null;
    return MediaItem(
      id: 'track|${t.provider}|${t.itemId}|$ctxKey',
      title: t.name, artist: t.artistsString,
      album: t.album?.name, duration: t.duration,
      artUri: artUri(provider, t), playable: true,
      extras: firstArtist != null
          ? {'android.media.metadata.SUBTITLE_LINK_MEDIA_ID': 'artist|$firstArtist'}
          : null,
    );
  }
}
