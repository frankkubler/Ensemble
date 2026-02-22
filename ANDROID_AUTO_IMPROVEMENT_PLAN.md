# Plan d'amélioration Android Auto - Ensemble

**Date**: 22 février 2026  
**Projet**: Ensemble - Client Music Assistant  
**Objectif**: Améliorer l'expérience utilisateur Android Auto pour la conduire en voiture

---

## 📊 État actuel de l'implémentation

### ✅ Fonctionnalités existantes

#### 1. Navigation & Browsing
- **Hiérarchie complète** : Home, Music, Audiobooks, Podcasts, Radio
- **Catégories Music** : Artists, Albums, Playlists, Favourites
- **Catégories Audiobooks** : Authors, Books, Series
- **Home personnalisé** : Reflète les paramètres de l'écran d'accueil utilisateur
- **Navigation profonde** : Artist → Albums → Tracks

#### 2. Lecture & Contrôle
- **Smart Queueing** : Lecture complète d'album/playlist à partir d'une piste
- **Cache de tracks** : Système de cache pour rejouer le contexte complet
- **Basculement automatique** : Switch vers le lecteur builtin à la lecture
- **Métadonnées complètes** : Titre, artiste, album, artwork

#### 3. Recherche vocale
- **Recherche implémentée** : `search()` method dans MassivAudioHandler
- **Résultats tracks** : Retourne les pistes correspondantes
- **Cache des résultats** : Stockés pour lecture ultérieure

#### 4. Technique
- **Audio routing** : AudioSession configurée correctement (fix récent)
- **Reconnexion automatique** : Gère les déconnexions API
- **Fallback sur cache** : Utilise les données locales si API indisponible
- **Logs détaillés** : Debugging facilité

### ⚠️ Limitations identifiées

#### Performance & UX
1. **Pas de pagination** : Toutes les listes sont chargées en mémoire
   - Albums: 500+ items peuvent saturer l'interface AA
   - Artists: Idem
   - Risk de timeout Android Auto (>5s)

2. **Artwork manquant** : Icônes vectorielles pour certaines catégories
   - Pas d'artwork dynamique pour Series
   - Fallback sur icônes système

3. **Pas de filtres** : Impossible de filtrer par provider ou favoris
   - Toute la bibliothèque est affichée
   - Pas de "Recently Played" distinct

4. **Navigation rigide** : Pas de raccourcis
   - Toujours 3-4 niveaux pour accéder à une piste
   - Pas de "Quick Access"

#### Recherche vocale
5. **Résultats limités** : Uniquement tracks
   - Pas d'albums, artists, playlists dans les résultats
   - Pas de suggestions

6. **Pas de recherche contextuelle** : 
   - "Play rock music" → ne filtre pas par genre
   - "Play my favorites" → ne marche pas
   - "Continue listening" → non supporté

#### Contenu
7. **Pas de "Now Playing"**
   - L'utilisateur ne voit pas ce qui joue actuellement dans la navigation
   - Pas de queue visible

8. **Genres absents**
   - Pas de navigation par genre
   - Pourtant disponible dans l'API MA

9. **Pas de "Recently Played"**
   - Seul "Recent Albums" existe dans Home
   - Pas de tracks récents accessibles

---

## 🎯 Améliorations proposées

> **Note** : Les améliorations D1 et D2 (Radio d'artiste et Shuffle) sont marquées comme **PRIORITÉ HAUTE** car elles sont essentielles pour l'usage en voiture. Elles permettent une découverte musicale rapide et une écoute variée sans manipulation du téléphone pendant la conduite.

### Priorité 1 : Performance & Stabilité ⚡

#### A1. Pagination intelligente
**Problème** : Listes trop longues saturent Android Auto  
**Solution** : Implémenter pagination virtualisée

```dart
// Ajouter dans _autoBuildAlbumList
Future<List<MediaItem>> _autoBuildAlbumList(
    MusicAssistantProvider provider,
    {int page = 0, int pageSize = 50}) async {
  final albums = SyncService.instance.cachedAlbums;
  final start = page * pageSize;
  final end = min(start + pageSize, albums.length);
  
  final items = albums.sublist(start, end).map((a) => MediaItem(
    id: 'album|${a.provider}|${a.itemId}',
    title: a.name,
    artist: a.artistsString,
    artUri: _autoArtUri(provider, a),
    playable: false,
  )).toList();
  
  // Ajouter "Load More" si nécessaire
  if (end < albums.length) {
    items.add(MediaItem(
      id: 'albums|page|${page + 1}',
      title: 'Load More (${albums.length - end} remaining)',
      playable: false,
    ));
  }
  
  return items;
}
```

**Impact** :
- ✅ Chargement <2s même avec 1000+ albums
- ✅ Réduit la mémoire utilisée
- ✅ Android Auto reste réactif

---

#### A2. Tri alphabétique avec navigation rapide
**Problème** : Difficile de trouver un élément précis dans une longue liste  
**Solution** : Ajouter des séparateurs alphabétiques

```dart
List<MediaItem> _autoBuildAlbumListWithSeparators(
    MusicAssistantProvider provider) {
  final albums = SyncService.instance.cachedAlbums;
  albums.sort((a, b) => a.name.compareTo(b.name));
  
  final items = <MediaItem>[];
  String? lastLetter;
  
  for (final album in albums.take(200)) { // Limiter à 200
    final firstLetter = album.name[0].toUpperCase();
    if (firstLetter != lastLetter) {
      // Ajouter séparateur alphabétique
      items.add(MediaItem(
        id: 'separator|$firstLetter',
        title: '─── $firstLetter ───',
        playable: false,
      ));
      lastLetter = firstLetter;
    }
    items.add(MediaItem(
      id: 'album|${album.provider}|${album.itemId}',
      title: album.name,
      artist: album.artistsString,
      artUri: _autoArtUri(provider, album),
      playable: false,
    ));
  }
  
  return items;
}
```

**Impact** :
- ✅ Navigation visuelle améliorée
- ✅ Trouve rapidement un album par lettre
- ✅ Interface plus claire

---

#### A3. Cache d'artwork avec préchargement
**Problème** : Latence lors du chargement des covers  
**Solution** : Précacher les artworks des 50 premiers items

```dart
// Nouveau service de cache d'artwork
class AndroidAutoArtworkCache {
  static final Map<String, Uri> _cache = {};
  
  static Future<void> precacheCategory(
      MusicAssistantProvider provider,
      List<ma.MediaItem> items) async {
    final futures = <Future<void>>[];
    for (final item in items.take(50)) {
      final key = '${item.provider}|${item.itemId}';
      if (!_cache.containsKey(key)) {
        futures.add(() async {
          final url = provider.getImageUrl(item, size: 256);
          if (url != null) {
            _cache[key] = Uri.parse(url);
          }
        }());
      }
    }
    await Future.wait(futures);
  }
  
  static Uri? getCached(String provider, String itemId) {
    return _cache['$provider|$itemId'];
  }
}
```

**Impact** :
- ✅ Affichage instantané des covers
- ✅ Moins de requêtes réseau
- ✅ Expérience fluide

---

### Priorité 2 : Amélioration de la recherche vocale 🎤

#### B1. Recherche multi-types
**Problème** : Seuls les tracks sont retournés  
**Solution** : Retourner albums, artists, playlists aussi

```dart
@override
Future<List<MediaItem>> search(String query,
    [Map<String, dynamic>? extras]) async {
  final provider = _autoProvider;
  if (provider == null || query.trim().isEmpty) return [];

  try {
    final results = await provider.searchWithCache(query);
    final items = <MediaItem>[];
    
    // 1. Tracks (playables immédiatement)
    final tracks = (results['tracks'] ?? []).whereType<ma.Track>().take(10).toList();
    if (tracks.isNotEmpty) {
      const ctxKey = 'search||tracks';
      _autoTrackCache[ctxKey] = tracks;
      items.addAll(tracks.map((t) => _autoTrackItem(provider, t, ctxKey)));
    }
    
    // 2. Albums (browsables)
    final albums = (results['albums'] ?? []).whereType<ma.Album>().take(10).toList();
    items.addAll(albums.map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}',
      title: a.name,
      artist: a.artistsString,
      artUri: _autoArtUri(provider, a),
      playable: false,
      extras: {'hint': 'Album'}, // Affiche le type
    )));
    
    // 3. Artists (browsables)
    final artists = (results['artists'] ?? []).whereType<ma.Artist>().take(5).toList();
    items.addAll(artists.map((a) => MediaItem(
      id: 'artist|${a.name}',
      title: a.name,
      artUri: _autoArtUri(provider, a),
      playable: false,
      extras: {'hint': 'Artist'},
    )));
    
    // 4. Playlists (browsables)
    final playlists = (results['playlists'] ?? []).whereType<ma.Playlist>().take(5).toList();
    items.addAll(playlists.map((p) => MediaItem(
      id: 'playlist|${p.provider}|${p.itemId}',
      title: p.name,
      artist: p.owner,
      artUri: _autoArtUri(provider, p),
      playable: false,
      extras: {'hint': 'Playlist'},
    )));
    
    _logger.log('AndroidAuto: search "$query" → ${items.length} results');
    return items;
  } catch (e) {
    _logger.log('AndroidAuto: search error: $e');
    return [];
  }
}
```

**Impact** :
- ✅ Recherche plus complète
- ✅ Types visuellement distingués
- ✅ Meilleure correspondance avec l'intention vocale

---

#### B2. Commandes vocales contextuelles
**Problème** : Pas de commandes naturelles genre "Play my favorites"  
**Solution** : Parser les commandes et router vers les bonnes fonctions

```dart
Future<List<MediaItem>> search(String query,
    [Map<String, dynamic>? extras]) async {
  final provider = _autoProvider;
  if (provider == null || query.trim().isEmpty) return [];

  final lowerQuery = query.toLowerCase().trim();
  
  // Détection de commandes contextuelles
  if (lowerQuery.contains('favorite') || lowerQuery.contains('favourite')) {
    return _handleFavoriteSearch(provider, lowerQuery);
  }
  
  if (lowerQuery.contains('recent') || lowerQuery.contains('played')) {
    return _handleRecentSearch(provider, lowerQuery);
  }
  
  if (lowerQuery.contains('continue')) {
    return _handleContinueListening(provider);
  }
  
  // Recherche normale
  return _handleNormalSearch(provider, query);
}

Future<List<MediaItem>> _handleFavoriteSearch(
    MusicAssistantProvider provider, String query) async {
  if (query.contains('track') || query.contains('song')) {
    return _autoBuildFavorites(provider);
  }
  if (query.contains('album')) {
    final albums = await provider.getFavoriteAlbums();
    return albums.take(20).map((a) => MediaItem(
      id: 'album|${a.provider}|${a.itemId}',
      title: a.name,
      artist: a.artistsString,
      artUri: _autoArtUri(provider, a),
      playable: false,
    )).toList();
  }
  // Par défaut, retourner tous les favoris
  return _autoBuildFavorites(provider);
}

Future<List<MediaItem>> _handleRecentSearch(
    MusicAssistantProvider provider, String query) async {
  final albums = await provider.getRecentAlbumsWithCache();
  return albums.take(20).map((a) => MediaItem(
    id: 'album|${a.provider}|${a.itemId}',
    title: a.name,
    artist: a.artistsString,
    artUri: _autoArtUri(provider, a),
    playable: false,
  )).toList();
}

Future<List<MediaItem>> _handleContinueListening(
    MusicAssistantProvider provider) async {
  final books = await provider.getInProgressAudiobooksWithCache();
  return books.map((b) => MediaItem(
    id: 'audiobook|${b.provider}|${b.itemId}',
    title: b.name,
    artist: b.authorsString,
    artUri: _autoArtUri(provider, b),
    playable: true,
  )).toList();
}
```

**Impact** :
- ✅ Commandes vocales naturelles fonctionnent
- ✅ Moins de friction pour accéder aux contenus
- ✅ Expérience plus intuitive

---

### Priorité 3 : Navigation enrichie 🗂️

#### C1. Ajouter "Now Playing" dans l'arbre
**Problème** : Impossible de voir/gérer la queue actuelle  
**Solution** : Ajouter une entrée "Now Playing" dans root

```dart
List<MediaItem> _autoBuildRoot() {
  final items = <MediaItem>[];
  
  // Ajouter "Now Playing" si quelque chose joue
  if (_currentMediaItem != null && _player.playing) {
    items.add(MediaItem(
      id: 'now_playing',
      title: 'Now Playing',
      artist: '${_currentMediaItem!.artist} - ${_currentMediaItem!.title}',
      artUri: _currentMediaItem!.artUri,
      playable: false, // Browsable pour voir la queue
      extras: {'icon': 'ic_auto_now_playing'},
    ));
  }
  
  items.addAll([
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
  ]);
  
  return items;
}

// Nouveau builder pour la queue
Future<List<MediaItem>> _autoBuildNowPlaying(
    MusicAssistantProvider provider) async {
  final queue = provider.currentQueue;
  if (queue.isEmpty) return [];
  
  return queue.map((t) => MediaItem(
    id: 'track|${t.provider}|${t.itemId}|queue||',
    title: t.name,
    artist: t.artistsString,
    album: t.album?.name,
    duration: t.duration,
    artUri: _autoArtUri(provider, t),
    playable: true,
    extras: t == provider.currentTrack ? {'current': true} : null,
  )).toList();
}
```

**Impact** :
- ✅ Visibilité de la queue actuelle
- ✅ Permet de sauter directement à une piste
- ✅ Indicateur visuel de la piste en cours

---

#### C2. Navigation par genre
**Problème** : Aucune navigation par genre disponible  
**Solution** : Ajouter une catégorie "Genres" dans Music

```dart
List<MediaItem> _autoBuildMusicCategories() {
  return [
    MediaItem(id: _autoIdArtists, title: 'Artists', playable: false,
        artUri: _iconArtist, extras: _gridHints),
    MediaItem(id: _autoIdAlbums, title: 'Albums', playable: false,
        artUri: _iconAlbum, extras: _gridHints),
    MediaItem(id: _autoIdGenres, title: 'Genres', playable: false,
        artUri: _iconGenre, extras: _gridHints), // NOUVEAU
    MediaItem(id: _autoIdPlaylists, title: 'Playlists', playable: false,
        artUri: _iconPlaylist, extras: _gridHints),
    MediaItem(id: _autoIdFavorites, title: 'Favourites', playable: false,
        artUri: _iconFavorite),
  ];
}

// Nouveau builder pour les genres
Future<List<MediaItem>> _autoBuildGenreList(
    MusicAssistantProvider provider) async {
  // Extraire les genres uniques des albums en cache
  final genres = <String>{};
  for (final album in SyncService.instance.cachedAlbums) {
    if (album.metadata?.genre != null) {
      genres.add(album.metadata!.genre!);
    }
  }
  
  final sortedGenres = genres.toList()..sort();
  
  return sortedGenres.map((g) => MediaItem(
    id: 'genre|$g',
    title: g,
    playable: false,
  )).toList();
}

// Builder pour les albums d'un genre
Future<List<MediaItem>> _autoBuildGenreAlbums(
    MusicAssistantProvider provider, String genre) async {
  final albums = SyncService.instance.cachedAlbums
      .where((a) => a.metadata?.genre == genre)
      .take(100)
      .toList();
  
  return albums.map((a) => MediaItem(
    id: 'album|${a.provider}|${a.itemId}',
    title: a.name,
    artist: a.artistsString,
    artUri: _autoArtUri(provider, a),
    playable: false,
  )).toList();
}
```

**Impact** :
- ✅ Découverte de musique par style
- ✅ Navigation alternative intuitive
- ✅ Utilisation des métadonnées existantes

---

#### C3. Quick Access / Raccourcis
**Problème** : Toujours 3-4 niveaux pour accéder à du contenu  
**Solution** : Ajouter une catégorie "Quick Access" dans root

```dart
List<MediaItem> _autoBuildRoot() {
  return [
    MediaItem(id: 'quick_access', title: 'Quick Access', playable: false,
        artUri: _iconStar), // NOUVEAU
    MediaItem(id: _autoIdHome, title: 'Home', playable: false,
        artUri: _iconHome),
    // ... reste inchangé
  ];
}

// Builder Quick Access
Future<List<MediaItem>> _autoBuildQuickAccess(
    MusicAssistantProvider provider) async {
  final items = <MediaItem>[];
  
  // 1. Derniers albums écoutés
  final recentAlbums = await provider.getRecentAlbumsWithCache();
  items.addAll(recentAlbums.take(5).map((a) => MediaItem(
    id: 'album|${a.provider}|${a.itemId}',
    title: '🕐 ${a.name}',
    artist: a.artistsString,
    artUri: _autoArtUri(provider, a),
    playable: false,
  )));
  
  // 2. Playlists favorites
  final favPlaylists = await provider.getFavoritePlaylists();
  items.addAll(favPlaylists.take(3).map((p) => MediaItem(
    id: 'playlist|${p.provider}|${p.itemId}',
    title: '⭐ ${p.name}',
    artist: p.owner,
    artUri: _autoArtUri(provider, p),
    playable: false,
  )));
  
  // 3. Stations radio favorites
  final favRadio = await provider.getFavoriteRadioStations();
  items.addAll(favRadio.take(3).map((s) => MediaItem(
    id: 'radio|${s.provider}|${s.itemId}',
    title: '📻 ${s.name}',
    artUri: _autoArtUri(provider, s),
    playable: true,
  )));
  
  return items;
}
```

**Impact** :
- ✅ Accès direct aux contenus les plus utilisés
- ✅ 1 seul niveau au lieu de 3-4
- ✅ Réduit la distraction en conduisant

---

### Priorité 4 : Lecture intelligente 🎲

#### D1. Radio basée sur un artiste
**Problème** : Impossible de lancer une radio similaire depuis un artiste ou un album  
**Solution** : Ajouter des options "Play Radio" pour artistes, albums et playlists

**Cas d'usage** : En voiture, l'utilisateur veut découvrir de la musique similaire sans navigation complexe

**Implémentation** :

```dart
// Dans _autoGetChildren, ajouter route pour actions contextuelles
Future<List<MediaItem>> _autoGetChildren(
    MusicAssistantProvider provider, String parentMediaId) async {
  // ... code existant ...
  
  // Nouveau : Actions contextuelles pour artistes/albums
  if (parentMediaId.startsWith('artist_actions|')) {
    final artistName = parentMediaId.substring('artist_actions|'.length);
    return _autoBuildArtistActions(provider, artistName);
  }
  
  if (parentMediaId.startsWith('album_actions|')) {
    final parts = parentMediaId.split('|');
    if (parts.length >= 3) {
      return _autoBuildAlbumActions(provider, parts[1], parts[2]);
    }
  }
  
  return [];
}

// Builder pour les actions artiste
Future<List<MediaItem>> _autoBuildArtistActions(
    MusicAssistantProvider provider, String artistName) async {
  return [
    // Option 1 : Jouer tous les tracks de l'artiste
    MediaItem(
      id: 'action_play_artist|$artistName',
      title: '▶️ Play All',
      artist: 'Play all songs by $artistName',
      playable: true,
    ),
    // Option 2 : Radio basée sur l'artiste
    MediaItem(
      id: 'action_radio_artist|$artistName',
      title: '📻 Artist Radio',
      artist: 'Discover similar artists and songs',
      playable: true,
    ),
    // Option 3 : Mode shuffle
    MediaItem(
      id: 'action_shuffle_artist|$artistName',
      title: '🔀 Shuffle All',
      artist: 'Shuffle all songs by $artistName',
      playable: true,
    ),
    // Option 4 : Voir les albums (navigation normale)
    MediaItem(
      id: 'artist|$artistName',
      title: '💿 View Albums',
      artist: 'Browse all albums by $artistName',
      playable: false,
    ),
  ];
}

// Builder pour les actions album
Future<List<MediaItem>> _autoBuildAlbumActions(
    MusicAssistantProvider provider, String alProvider, String alItemId) async {
  final album = SyncService.instance.cachedAlbums.firstWhere(
    (a) => a.provider == alProvider && a.itemId == alItemId,
    orElse: () => throw Exception('Album not found'),
  );
  
  return [
    // Option 1 : Jouer l'album normalement
    MediaItem(
      id: 'action_play_album|$alProvider|$alItemId',
      title: '▶️ Play Album',
      artist: 'Play ${album.name} in order',
      artUri: _autoArtUri(provider, album),
      playable: true,
    ),
    // Option 2 : Radio basée sur l'album
    MediaItem(
      id: 'action_radio_album|$alProvider|$alItemId',
      title: '📻 Album Radio',
      artist: 'Discover similar albums and songs',
      artUri: _autoArtUri(provider, album),
      playable: true,
    ),
    // Option 3 : Mode shuffle
    MediaItem(
      id: 'action_shuffle_album|$alProvider|$alItemId',
      title: '🔀 Shuffle Album',
      artist: 'Shuffle ${album.name}',
      artUri: _autoArtUri(provider, album),
      playable: true,
    ),
    // Option 4 : Voir les tracks (navigation normale)
    MediaItem(
      id: 'album|$alProvider|$alItemId',
      title: '🎵 View Tracks',
      artist: 'Browse all tracks in ${album.name}',
      artUri: _autoArtUri(provider, album),
      playable: false,
    ),
  ];
}

// Modifier _autoBuildArtistList pour pointer vers actions
List<MediaItem> _autoBuildArtistList(MusicAssistantProvider provider) {
  final artists = SyncService.instance.cachedArtists;
  _logger.log('AndroidAuto: Artists: ${artists.length}');
  return artists.map((a) => MediaItem(
    id: 'artist_actions|${a.name}', // CHANGÉ : pointer vers menu actions
    title: a.name,
    artUri: _autoArtUri(provider, a),
    playable: false,
  )).toList();
}

// Modifier _autoBuildAlbumList pour pointer vers actions
List<MediaItem> _autoBuildAlbumList(MusicAssistantProvider provider) {
  final albums = SyncService.instance.cachedAlbums;
  _logger.log('AndroidAuto: Albums: ${albums.length}');
  return albums.map((a) => MediaItem(
    id: 'album_actions|${a.provider}|${a.itemId}', // CHANGÉ : pointer vers menu actions
    title: a.name,
    artist: a.artistsString,
    artUri: _autoArtUri(provider, a),
    playable: false,
  )).toList();
}
```

**Gérer la lecture dans playFromMediaId** :

```dart
@override
Future<void> playFromMediaId(String mediaId,
    [Map<String, dynamic>? extras]) async {
  // ... code existant ...
  
  try {
    // NOUVEAU : Gérer les actions contextuelles
    
    // Radio d'artiste
    if (mediaId.startsWith('action_radio_artist|')) {
      final artistName = mediaId.substring('action_radio_artist|'.length);
      await _playArtistRadio(provider, playerId, artistName);
      return;
    }
    
    // Shuffle d'artiste
    if (mediaId.startsWith('action_shuffle_artist|')) {
      final artistName = mediaId.substring('action_shuffle_artist|'.length);
      await _playArtistShuffle(provider, playerId, artistName);
      return;
    }
    
    // Jouer tous les tracks d'artiste
    if (mediaId.startsWith('action_play_artist|')) {
      final artistName = mediaId.substring('action_play_artist|'.length);
      await _playArtistAll(provider, playerId, artistName);
      return;
    }
    
    // Radio d'album
    if (mediaId.startsWith('action_radio_album|')) {
      final parts = mediaId.split('|');
      if (parts.length >= 3) {
        await _playAlbumRadio(provider, playerId, parts[1], parts[2]);
      }
      return;
    }
    
    // Shuffle d'album
    if (mediaId.startsWith('action_shuffle_album|')) {
      final parts = mediaId.split('|');
      if (parts.length >= 3) {
        await _playAlbumShuffle(provider, playerId, parts[1], parts[2]);
      }
      return;
    }
    
    // Jouer album normalement
    if (mediaId.startsWith('action_play_album|')) {
      final parts = mediaId.split('|');
      if (parts.length >= 3) {
        final album = SyncService.instance.cachedAlbums.firstWhere(
          (a) => a.provider == parts[1] && a.itemId == parts[2],
          orElse: () => throw Exception('Album not found'),
        );
        await provider.api!.playAlbum(playerId, album);
      }
      return;
    }
    
    // ... code existant pour tracks, radio, etc. ...
  } catch (e) {
    _logger.log('AndroidAuto: playFromMediaId error: $e');
  }
}

// Helpers pour les différents modes de lecture

Future<void> _playArtistRadio(
    MusicAssistantProvider provider, String playerId, String artistName) async {
  _logger.log('AndroidAuto: Playing artist radio for $artistName');
  
  // Récupérer un track représentatif de l'artiste
  final albums = await provider.getArtistAlbumsWithCache(artistName);
  if (albums.isEmpty) return;
  
  final tracks = await provider.getAlbumTracksWithCache(
    albums.first.provider,
    albums.first.itemId,
  );
  if (tracks.isEmpty) return;
  
  // Lancer la radio basée sur la première piste
  await provider.playRadio(playerId, tracks.first);
}

Future<void> _playArtistShuffle(
    MusicAssistantProvider provider, String playerId, String artistName) async {
  _logger.log('AndroidAuto: Shuffling artist $artistName');
  
  // Récupérer tous les albums de l'artiste
  final albums = await provider.getArtistAlbumsWithCache(artistName);
  if (albums.isEmpty) return;
  
  // Récupérer tous les tracks
  final allTracks = <ma.Track>[];
  for (final album in albums.take(10)) { // Limiter à 10 albums max
    final tracks = await provider.getAlbumTracksWithCache(
      album.provider,
      album.itemId,
    );
    allTracks.addAll(tracks);
  }
  
  if (allTracks.isEmpty) return;
  
  // Mélanger les tracks
  allTracks.shuffle();
  
  // Jouer avec shuffle activé
  await provider.playTracks(playerId, allTracks);
  await provider.toggleShuffle(playerId, true);
}

Future<void> _playArtistAll(
    MusicAssistantProvider provider, String playerId, String artistName) async {
  _logger.log('AndroidAuto: Playing all tracks from $artistName');
  
  // Récupérer tous les albums de l'artiste
  final albums = await provider.getArtistAlbumsWithCache(artistName);
  if (albums.isEmpty) return;
  
  // Trier par année (plus récents en premier)
  albums.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
  
  // Récupérer tous les tracks
  final allTracks = <ma.Track>[];
  for (final album in albums) {
    final tracks = await provider.getAlbumTracksWithCache(
      album.provider,
      album.itemId,
    );
    allTracks.addAll(tracks);
  }
  
  if (allTracks.isEmpty) return;
  await provider.playTracks(playerId, allTracks);
}

Future<void> _playAlbumRadio(
    MusicAssistantProvider provider, String playerId,
    String alProvider, String alItemId) async {
  _logger.log('AndroidAuto: Playing album radio');
  
  final tracks = await provider.getAlbumTracksWithCache(alProvider, alItemId);
  if (tracks.isEmpty) return;
  
  // Lancer la radio basée sur la première piste
  await provider.playRadio(playerId, tracks.first);
}

Future<void> _playAlbumShuffle(
    MusicAssistantProvider provider, String playerId,
    String alProvider, String alItemId) async {
  _logger.log('AndroidAuto: Shuffling album');
  
  final tracks = await provider.getAlbumTracksWithCache(alProvider, alItemId);
  if (tracks.isEmpty) return;
  
  // Mélanger les tracks
  final shuffled = List<ma.Track>.from(tracks)..shuffle();
  
  // Jouer avec shuffle activé
  await provider.playTracks(playerId, shuffled);
  await provider.toggleShuffle(playerId, true);
}
```

**Impact** :
- ✅ **Radio d'artiste** : Mode découverte en 2 clics depuis un artiste
- ✅ **Shuffle** : Lecture aléatoire immédiate pour artistes/albums
- ✅ **Flexibilité** : Menu d'actions clair avec 4 options par item
- ✅ **UX voiture** : Réduit drastiquement la navigation nécessaire

**Variante alternative** : Utiliser des MediaItem avec `extras` pour afficher des boutons d'action directement dans la liste d'albums/artistes (si Android Auto le supporte).

---

#### D2. Shuffle pour playlists
**Problème** : Pas de lecture aléatoire pour les playlists  
**Solution** : Ajouter un item "🔀 Shuffle Playlist" en tête de liste

```dart
Future<List<MediaItem>> _autoBuildPlaylistTracks(
    MusicAssistantProvider provider, String plProvider, String plItemId) async {
  final tracks =
      await provider.getPlaylistTracksWithCache(plProvider, plItemId);
  final ctxKey = 'plist|$plProvider|$plItemId';
  _autoTrackCache[ctxKey] = tracks;
  
  final items = <MediaItem>[];
  
  // NOUVEAU : Ajouter option shuffle en tête
  if (tracks.length > 1) {
    items.add(MediaItem(
      id: 'action_shuffle_playlist|$plProvider|$plItemId',
      title: '🔀 Shuffle Playlist',
      artist: 'Play ${tracks.length} tracks in random order',
      playable: true,
    ));
  }
  
  // Tracks normaux
  items.addAll(tracks.map((t) => _autoTrackItem(provider, t, ctxKey)));
  
  return items;
}

// Gérer dans playFromMediaId
if (mediaId.startsWith('action_shuffle_playlist|')) {
  final parts = mediaId.split('|');
  if (parts.length >= 3) {
    final ctxKey = 'plist|${parts[1]}|${parts[2]}';
    final tracks = _autoTrackCache[ctxKey];
    if (tracks != null && tracks.isNotEmpty) {
      final shuffled = List<ma.Track>.from(tracks)..shuffle();
      await provider.playTracks(playerId, shuffled);
      await provider.toggleShuffle(playerId, true);
    }
  }
  return;
}
```

**Impact** :
- ✅ Option shuffle visible en tête de playlist
- ✅ Pas de menu supplémentaire nécessaire
- ✅ Cohérent avec l'app mobile

---

### Priorité 5 : UX & Polish 💎

#### E1. Indicateurs de progression (audiobooks/podcasts)
**Problème** : Pas d'indicateur de progression dans les listes  
**Solution** : Afficher le % écouté dans le titre/subtitle

```dart
Future<List<MediaItem>> _autoBuildAudiobookList(
    MusicAssistantProvider provider) async {
  final books = SyncService.instance.cachedAudiobooks;
  
  return books.map((b) {
    String title = b.name;
    String? subtitle = b.authorsString;
    
    // Ajouter progression si en cours
    if (b.position != null && b.position! > Duration.zero) {
      final percent = (b.position!.inSeconds / (b.duration?.inSeconds ?? 1) * 100).toInt();
      subtitle = '$subtitle • ${percent}% écouté';
    }
    
    return MediaItem(
      id: 'audiobook|${b.provider}|${b.itemId}',
      title: title,
      artist: subtitle,
      artUri: _autoArtUri(provider, b),
      playable: true,
      extras: b.position != null ? {'progress': percent} : null,
    );
  }).toList();
}
```

**Impact** :
- ✅ Visibilité immédiate de la progression
- ✅ Facilite la reprise d'écoute
- ✅ Cohérent avec l'app principale

---

#### E2. Provider badges
**Problème** : Pas de distinction visuelle entre Spotify, YT Music, etc.  
**Solution** : Afficher l'origine dans le subtitle ou extras

```dart
MediaItem _autoTrackItem(
    MusicAssistantProvider provider, ma.Track t, String ctxKey) {
  // Formater le provider de manière lisible
  String providerName = t.provider;
  if (providerName.contains('spotify')) providerName = 'Spotify';
  else if (providerName.contains('ytmusic')) providerName = 'YouTube Music';
  else if (providerName.contains('library')) providerName = 'Library';
  
  return MediaItem(
    id: 'track|${t.provider}|${t.itemId}|$ctxKey',
    title: t.name,
    artist: '${t.artistsString} • $providerName', // Ajout du provider
    album: t.album?.name,
    duration: t.duration,
    artUri: _autoArtUri(provider, t),
    playable: true,
  );
}
```

**Impact** :
- ✅ Transparence sur la source
- ✅ Facilite le debug
- ✅ Cohérent avec l'app principale

---

#### E3. Gestion d'erreurs gracieuse
**Problème** : Erreurs silencieuses en cas de déconnexion  
**Solution** : Afficher des messages informatifs

```dart
Future<List<MediaItem>> getChildren(String parentMediaId,
    [Map<String, dynamic>? options]) async {
  final provider = _autoProvider;
  if (provider == null) {
    return [MediaItem(
      id: 'error|no_provider',
      title: 'App initializing...',
      artist: 'Please wait',
      playable: false,
    )];
  }

  // Vérifier la connexion
  if (!provider.isConnected) {
    _logger.log('AndroidAuto: provider disconnected, starting reconnect');
    provider.checkAndReconnect();
    
    // Retourner un message pendant la reconnexion
    return [MediaItem(
      id: 'error|reconnecting',
      title: 'Reconnecting to Music Assistant...',
      artist: 'Cached content available below',
      playable: false,
    )];
  }

  try {
    final result = await _autoGetChildren(provider, parentMediaId);
    if (result.isEmpty) {
      return [MediaItem(
        id: 'error|empty',
        title: 'No content available',
        artist: 'Try refreshing your library in the app',
        playable: false,
      )];
    }
    return result;
  } catch (e, st) {
    _logger.log('AndroidAuto: getChildren error: $e\n$st');
    return [MediaItem(
      id: 'error|exception',
      title: 'Error loading content',
      artist: 'Check your connection and try again',
      playable: false,
    )];
  }
}
```

**Impact** :
- ✅ Utilisateur informé de ce qui se passe
- ✅ Moins de confusion en cas d'erreur
- ✅ Meilleure expérience globale

---

## 📋 Plan d'implémentation

### Phase 1 : Fondations (1 semaine)
- [ ] A1. Pagination intelligente (2 jours)
- [ ] A2. Tri alphabétique avec séparateurs (1 jour)
- [ ] A3. Cache d'artwork (2 jours)
- [ ] E3. Gestion d'erreurs gracieuse (1 jour)

**Tests** : Vérifier les temps de chargement, stabilité avec grandes bibliothèques

---

### Phase 2 : Recherche vocale (1 semaine)
- [ ] B1. Recherche multi-types (3 jours)
- [ ] B2. Commandes vocales contextuelles (3 jours)

**Tests** : Tester commandes vocales réelles en voiture/DHU

---

### Phase 3 : Navigation (1 semaine)
- [ ] C1. "Now Playing" dans l'arbre (2 jours)
- [ ] C2. Navigation par genre (2 jours)
- [ ] C3. Quick Access (2 jours)

**Tests** : Navigation fluide, compteur de clics réduit

---

### Phase 4 : Lecture intelligente ⭐ PRIORITÉ HAUTE (4-5 jours)
- [ ] D1. Radio basée sur artiste (2 jours)
  - Actions contextuelles pour artistes
  - Actions contextuelles pour albums
  - Gestion playFromMediaId
  - Tests avec différents providers (Spotify, YTMusic, etc.)
- [ ] D2. Shuffle pour playlists/albums (1 jour)
  - Option shuffle en tête de playlist
  - Shuffle pour albums
  - Shuffle pour artistes
- [ ] Tests intensifs radio et shuffle (1-2 jours)
  - Vérifier qualité des recommandations radio
  - Tester shuffle avec grandes playlists (500+ tracks)
  - Compatibilité avec tous les providers

**Tests** : Fonctionnalités essentielles pour l'usage en voiture

---

### Phase 5 : Polish (3-4 jours)
- [ ] E1. Indicateurs de progression (1 jour)
- [ ] E2. Provider badges (1 jour)
- [ ] Tests intensifs et corrections bugs (2 jours)

---

## 🎨 Améliorations visuelles (optionnel)

### E1. Icônes personnalisées
Actuellement : Icônes vectorielles Android (ic_auto_*)  
**Amélioration** : Créer des icônes custom alignées avec l'identité visuelle Ensemble

**Fichiers à créer** :
- `android/app/src/main/res/drawable/ic_auto_now_playing.xml`
- `android/app/src/main/res/drawable/ic_auto_genre.xml`
- `android/app/src/main/res/drawable/ic_auto_star.xml` (Quick Access)

### E2. Content style hints améliorés
```dart
// Utiliser les hints pour guider l'affichage AA
static const _listHints = {
  'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 1, // Liste
  'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
};

static const _gridHints = {
  'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2, // Grille
  'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 2,
};

static const _categoryHints = {
  'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 3, // Grandes icônes
  'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 3,
};
```

**Application** :
- Grille pour : Albums, Podcasts, Radio, Genres
- Liste pour : Tracks, Artists, Queue
- Catégories pour : Root, Music categories

---

## 📊 KPIs de succès

### Performance
- ⏱️ Temps de chargement racine : < 500ms
- ⏱️ Temps de chargement catégorie : < 2s
- ⏱️ Artwork affiché : < 1s pour 90% des items
- 💾 Mémoire utilisée : < 100MB même avec 1000+ albums

### UX
- 🎯 Clics pour accéder à une piste : Réduit de 4 à 2 (Quick Access)
- 🎯 Clics pour lancer une radio d'artiste : **2 clics maximum** ⭐
- 🎯 Clics pour shuffle un album : **2 clics maximum** ⭐
- 🔊 Commandes vocales réussies : > 80%
- ⭐ Satisfaction utilisateur : > 4/5
- ⚡ Taux de succès première lecture : > 95%
- 🎲 Utilisation mode radio : Mesurer adoption (objectif > 20% des sessions) ⭐
- 🔀 Utilisation shuffle : Mesurer adoption (objectif > 30% des sessions) ⭐

### Stabilité
- 🛡️ Crashes : < 0.1% des sessions
- 🔄 Reconnexions réussies : > 95%
- ❌ Erreurs gérées gracieusement : 100%
- 📻 Taux de succès lancement radio : > 90% ⭐

### Nouveaux KPIs (fonctionnalités D1 & D2)
- 🎵 Temps moyen pour lancer une radio d'artiste : < 10 secondes
- 🔀 Temps moyen pour shuffle un album : < 5 secondes
- 📊 % d'utilisateurs utilisant radio vs lecture normale : viser 25%
- 🎯 % d'utilisateurs utilisant shuffle : viser 35%

---

## 🧪 Tests recommandés

### Tests unitaires
```dart
// test/services/audio/massiv_audio_handler_test.dart
void main() {
  group('AndroidAuto pagination', () {
    test('should paginate albums correctly', () async {
      // ...
    });
    
    test('should show "Load More" when needed', () async {
      // ...
    });
  });
  
  group('AndroidAuto search', () {
    test('should return multi-type results', () async {
      // ...
    });
    
    test('should handle contextual commands', () async {
      // ...
    });
  });
}
```

### Tests d'intégration
1. **DHU (Desktop Head Unit)** : Simulateur Android Auto
   ```bash
   ~/Library/Android/sdk/extras/google/auto/desktop-head-unit
   ```

2. **Tests en voiture** : 
   - Avec Bluetooth
   - Avec USB (meilleure qualité)
   - Différents modèles de voiture

3. **Tests de stress** :
   - Bibliothèques de 5000+ albums
   - Connexion instable
   - Changements rapides de contexte

### Checklist de validation
- [ ] Toutes les catégories s'affichent
- [ ] Artwork présent pour >90% des items
- [ ] Recherche vocale fonctionne avec commandes naturelles
- [ ] Playback démarre en <3s
- [ ] Reconnexion automatique fonctionne
- [ ] Pas de timeout Android Auto
- [ ] Queue visible et gérable
- [ ] Quick Access accessible en 1 clic
- [ ] Messages d'erreur clairs
- [ ] **⭐ Radio d'artiste fonctionne pour tous les providers** (Spotify, YTMusic, Qobuz, etc.)
- [ ] **⭐ Shuffle fonctionne pour albums, artistes et playlists**
- [ ] **⭐ Menu d'actions s'affiche correctement** (4 options claires)
- [ ] **⭐ Qualité des recommandations radio satisfaisante**
- [ ] **⭐ Transitions fluides entre modes de lecture** (normal → shuffle → radio)

### Tests spécifiques Radio & Shuffle
1. **Radio d'artiste** :
   - [ ] Lancer radio depuis artiste Spotify
   - [ ] Lancer radio depuis artiste YTMusic
   - [ ] Lancer radio depuis artiste Library (fallback)
   - [ ] Vérifier que les recommandations sont pertinentes
   - [ ] Tester avec artistes de différents genres

2. **Shuffle** :
   - [ ] Shuffle playlist de 10 tracks
   - [ ] Shuffle playlist de 500+ tracks
   - [ ] Shuffle album
   - [ ] Shuffle tous les tracks d'un artiste (100+ tracks)
   - [ ] Vérifier que l'ordre est bien aléatoire (pas de pattern)

3. **Menu d'actions** :
   - [ ] Menu s'affiche en <1s après sélection artiste
   - [ ] Les 4 options sont claires et distinctes
   - [ ] Navigation vers albums fonctionne (4e option)
   - [ ] Aucun crash lors de sélection rapide des options

---

## 🚀 Gains attendus

### Quantitatifs
- **-50%** de clics pour accéder au contenu (Quick Access)
- **-70%** de temps de chargement (pagination + cache)
- **+200%** de contenu accessible vocalement (multi-types)
- **+100%** de visibilité sur l'état (Now Playing, erreurs)

---

## 📝 Notes techniques

### Compatibilité
- **Android Auto** : Testé sur API 28+ (Android 9+)
- **minSdkVersion** : 23 (actuel) ✅
- **Regression risks** : Faibles, ajouts non-breaking

### Dépendances
Aucune nouvelle dépendance nécessaire. Toutes les améliorations utilisent :
- `audio_service` (existant)
- `rxdart` (existant)
- API Music Assistant (existant)

### Architecture
Les améliorations s'intègrent dans l'architecture existante :
```
MassivAudioHandler
  ├── getChildren() ← Pagination, séparateurs
  ├── search() ← Multi-types, contexte
  ├── playFromMediaId() ← Inchangé
  └── _autoBuild*() ← Nouveaux builders
      ├── _autoBuildQuickAccess()
      ├── _autoBuildNowPlaying()
      ├── _autoBuildGenreList()
      └── ...
```

---

## 🔄 Maintenance future

### Monitoring
- Logs Android Auto dans production (opt-in)
- Metrics de performance (temps chargement, taux succès)
- Feedback utilisateurs (formulaire in-app)

### Évolutions possibles (V2)
1. **⭐ Ajouter la lecture intelligente** avec Radio d'artiste et Shuffle (PRIORITÉ HAUTE)
5. **Améliorer le polish** avec des indicateurs et une meilleure gestion d'erreurs

**Timeline totale** : 4-5 semaines  
**Effort** : 1 développeur à temps plein  
**ROI** : Très élevé - améliore significativement l'UX en voiture

### Fonctionnalités incontournables pour Android Auto
Les améliorations **D1 (Radio d'artiste)** et **D2 (Shuffle)** sont considérées comme **essentielles** car :
- ✅ Réduisent drastiquement les manipulations nécessaires en conduisant
- ✅ Permettent une découverte musicale passive et sûre
- ✅ Alignent l'expérience Android Auto avec l'app mobile
- ✅ Sont des fonctionnalités standard dans competing apps (Spotify, Apple Music)
- ✅ Utilisent l'API Music Assistant existante (`playRadio()`, `toggleShuffle()`)

---

**Prochaine étape recommandée** : 
1. **Phase 1** (fondations) pour la stabilité
2. **Phase 4** (lecture intelligente) pour les fonctionnalités critiques ⭐
3. **Phase 2** (recherche vocale) pour l'accessibilité
4. **Phase 3** (navigation enrichie) pour la découvrabilité
5. **Phase 5** (polish) pour le raffinement

**Alternative rapide** : Si timeline courte, prioriser Phase 4 en premier pour impact utilisateur maximal

### Documentation
- [Android Auto Media Apps](https://developer.android.com/training/cars/media)
- [audio_service package](https://pub.dev/packages/audio_service)
- [Music Assistant API](https://music-assistant.io/integration/api/)

### Outils
- **DHU** : Desktop Head Unit émulateur
- **adb logcat** : Debugging Android Auto
- **Charles Proxy** : Monitoring requêtes réseau

---

## ✅ Conclusion

L'implémentation Android Auto actuelle d'Ensemble est **solide et fonctionnelle**. Les améliorations proposées visent à :

1. **Optimiser les performances** pour les grandes bibliothèques
2. **Enrichir la recherche vocale** pour une expérience mains-libres
3. **Simplifier la navigation** avec Quick Access et Now Playing
4. **Améliorer le polish** avec des indicateurs et une meilleure gestion d'erreurs

**Timeline totale** : 3-4 semaines  
**Effort** : 1 développeur à temps plein  
**ROI** : Élevé - améliore significativement l'UX en voiture

---

**Prochaine étape** : Valider les priorités avec l'équipe et commencer par la **Phase 1** (fondations) qui apporte les gains les plus immédiats.
