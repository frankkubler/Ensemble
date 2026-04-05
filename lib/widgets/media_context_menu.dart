import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../models/media_item.dart';
import '../providers/music_assistant_provider.dart';
import '../widgets/global_player_overlay.dart' show GlobalPlayerOverlay, BottomSpacing;
import '../theme/theme_provider.dart';
import '../l10n/app_localizations.dart';
import '../services/debug_logger.dart';

/// The type of media item for the context menu
enum ContextMenuMediaType {
  album,
  artist,
  playlist,
  track,
  audiobook,
  podcast,
  podcastEpisode,
  radio,
}

/// Shows a floating context menu for media actions
class MediaContextMenu {
  static OverlayEntry? _currentOverlay;

  /// Show the context menu at the given position
  static void show({
    required BuildContext context,
    required Offset position,
    required ContextMenuMediaType mediaType,
    required dynamic item,
    required bool isFavorite,
    required bool isInLibrary,
    ColorScheme? adaptiveColorScheme,
    VoidCallback? onDismiss,
    VoidCallback? onToggleFavorite,
    VoidCallback? onToggleLibrary,
    bool showTopRow = true,
    // Optional layout/sort controls for detail screens
    String? sortOrder,
    VoidCallback? onToggleSort,
    String? viewMode,
    VoidCallback? onCycleView,
    // Episode-specific callbacks (for podcastEpisode type)
    VoidCallback? onPlay,
    VoidCallback? onPlayOn,
    VoidCallback? onAddToQueue,
    VoidCallback? onViewDetails,
  }) {
    // Close any existing menu
    hide();

    // Haptic feedback for long-press menu
    HapticFeedback.mediumImpact();

    final overlay = Navigator.of(context).overlay;
    if (overlay == null) return;

    _currentOverlay = OverlayEntry(
      builder: (context) => _MediaContextMenuOverlay(
        position: position,
        mediaType: mediaType,
        item: item,
        isFavorite: isFavorite,
        isInLibrary: isInLibrary,
        adaptiveColorScheme: adaptiveColorScheme,
        onToggleFavorite: onToggleFavorite,
        onToggleLibrary: onToggleLibrary,
        showTopRow: showTopRow,
        sortOrder: sortOrder,
        onToggleSort: onToggleSort,
        viewMode: viewMode,
        onCycleView: onCycleView,
        onPlay: onPlay,
        onPlayOn: onPlayOn,
        onAddToQueue: onAddToQueue,
        onViewDetails: onViewDetails,
        onDismiss: () {
          hide();
          onDismiss?.call();
        },
      ),
    );

    overlay.insert(_currentOverlay!);
  }

  /// Hide the current context menu
  static void hide() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}

class _MediaContextMenuOverlay extends StatefulWidget {
  final Offset position;
  final ContextMenuMediaType mediaType;
  final dynamic item;
  final bool isFavorite;
  final bool isInLibrary;
  final ColorScheme? adaptiveColorScheme;
  final VoidCallback onDismiss;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleLibrary;
  final bool showTopRow;
  // Optional layout/sort controls
  final String? sortOrder;
  final VoidCallback? onToggleSort;
  final String? viewMode;
  final VoidCallback? onCycleView;
  // Episode-specific callbacks
  final VoidCallback? onPlay;
  final VoidCallback? onPlayOn;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onViewDetails;

  const _MediaContextMenuOverlay({
    required this.position,
    required this.mediaType,
    required this.item,
    required this.isFavorite,
    required this.isInLibrary,
    this.adaptiveColorScheme,
    required this.onDismiss,
    this.onToggleFavorite,
    this.onToggleLibrary,
    this.showTopRow = true,
    this.sortOrder,
    this.onToggleSort,
    this.viewMode,
    this.onCycleView,
    this.onPlay,
    this.onPlayOn,
    this.onAddToQueue,
    this.onViewDetails,
  });

  @override
  State<_MediaContextMenuOverlay> createState() => _MediaContextMenuOverlayState();
}

class _MediaContextMenuOverlayState extends State<_MediaContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  static final _logger = DebugLogger();
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  /// Get the item name for display
  String get _itemName {
    switch (widget.mediaType) {
      case ContextMenuMediaType.album:
        return (widget.item as Album).name;
      case ContextMenuMediaType.artist:
        return (widget.item as Artist).name;
      case ContextMenuMediaType.playlist:
        return (widget.item as Playlist).name;
      case ContextMenuMediaType.track:
        return (widget.item as Track).name;
      case ContextMenuMediaType.audiobook:
        return (widget.item as Audiobook).name;
      case ContextMenuMediaType.podcast:
      case ContextMenuMediaType.podcastEpisode:
      case ContextMenuMediaType.radio:
        return (widget.item as MediaItem).name;
    }
  }

  /// Play the item instantly using selected player
  Future<void> _play(BuildContext context) async {
    final maProvider = context.read<MusicAssistantProvider>();
    final player = maProvider.selectedPlayer;
    final l10n = S.of(context)!;

    if (player == null) {
      _showSnackBar(context, l10n.noPlayerSelected);
      return;
    }

    widget.onDismiss();

    try {
      switch (widget.mediaType) {
        case ContextMenuMediaType.album:
          final album = widget.item as Album;
          await maProvider.api?.playAlbum(player.playerId, album);
          break;
        case ContextMenuMediaType.artist:
          // For artists, play artist radio (no direct "play artist" method)
          final artist = widget.item as Artist;
          await maProvider.api?.playArtistRadio(player.playerId, artist);
          break;
        case ContextMenuMediaType.playlist:
          final playlist = widget.item as Playlist;
          await maProvider.api?.playPlaylist(player.playerId, playlist);
          break;
        case ContextMenuMediaType.track:
          final track = widget.item as Track;
          await maProvider.playTracks(player.playerId, [track], startIndex: 0);
          break;
        case ContextMenuMediaType.audiobook:
          final audiobook = widget.item as Audiobook;
          await maProvider.api?.playAudiobook(player.playerId, audiobook);
          break;
        case ContextMenuMediaType.podcast:
          // Podcasts are shows, not directly playable - would need to play latest episode
          break;
        case ContextMenuMediaType.podcastEpisode:
          // Episodes are handled via onPlay callback
          break;
        case ContextMenuMediaType.radio:
          final station = widget.item as MediaItem;
          await maProvider.api?.playRadioStation(player.playerId, station);
          break;
      }
    } catch (e) {
      _logger.log('Error playing item: $e');
    }
  }

  /// Show player selector for play
  void _playOn(BuildContext context) {
    final maProvider = context.read<MusicAssistantProvider>();
    final l10n = S.of(context)!;

    widget.onDismiss();

    GlobalPlayerOverlay.showPlayerSelectorForAction(
      contextHint: l10n.playOn,
      onPlayerSelected: (player) async {
        try {
          switch (widget.mediaType) {
            case ContextMenuMediaType.album:
              final album = widget.item as Album;
              await maProvider.api?.playAlbum(player.playerId, album);
              break;
            case ContextMenuMediaType.artist:
              final artist = widget.item as Artist;
              await maProvider.api?.playArtistRadio(player.playerId, artist);
              break;
            case ContextMenuMediaType.playlist:
              final playlist = widget.item as Playlist;
              await maProvider.api?.playPlaylist(player.playerId, playlist);
              break;
            case ContextMenuMediaType.track:
              final track = widget.item as Track;
              await maProvider.playTracks(player.playerId, [track], startIndex: 0);
              break;
            case ContextMenuMediaType.audiobook:
              final audiobook = widget.item as Audiobook;
              await maProvider.api?.playAudiobook(player.playerId, audiobook);
              break;
            case ContextMenuMediaType.podcast:
              // Podcasts are shows, not directly playable
              break;
            case ContextMenuMediaType.podcastEpisode:
              // Episodes are handled via onPlayOn callback
              break;
            case ContextMenuMediaType.radio:
              final station = widget.item as MediaItem;
              await maProvider.api?.playRadioStation(player.playerId, station);
              break;
          }
        } catch (e) {
          _logger.log('Error playing item: $e');
        }
      },
    );
  }

  /// Add to queue instantly using selected player
  Future<void> _addToQueue(BuildContext context) async {
    final maProvider = context.read<MusicAssistantProvider>();
    final player = maProvider.selectedPlayer;
    final l10n = S.of(context)!;

    if (player == null) {
      _showSnackBar(context, l10n.noPlayerSelected);
      return;
    }

    widget.onDismiss();

    try {
      switch (widget.mediaType) {
        case ContextMenuMediaType.album:
          final album = widget.item as Album;
          final tracks = await maProvider.api?.getAlbumTracks(album.provider, album.itemId);
          if (tracks != null && tracks.isNotEmpty) {
            await maProvider.addTracksToQueue(player.playerId, tracks);
            if (context.mounted) _showSnackBar(context, l10n.albumAddedToQueue);
          }
          break;
        case ContextMenuMediaType.playlist:
          final playlist = widget.item as Playlist;
          final tracks = await maProvider.api?.getPlaylistTracks(playlist.provider, playlist.itemId);
          if (tracks != null && tracks.isNotEmpty) {
            await maProvider.addTracksToQueue(player.playerId, tracks);
            if (context.mounted) _showSnackBar(context, l10n.tracksAddedToQueue);
          }
          break;
        case ContextMenuMediaType.track:
          final track = widget.item as Track;
          await maProvider.addTracksToQueue(player.playerId, [track]);
          if (context.mounted) _showSnackBar(context, l10n.trackAddedToQueue);
          break;
        case ContextMenuMediaType.artist:
        case ContextMenuMediaType.audiobook:
        case ContextMenuMediaType.podcast:
        case ContextMenuMediaType.podcastEpisode:
        case ContextMenuMediaType.radio:
          // These types don't support direct queue addition (episodes use callback)
          break;
      }
    } catch (e) {
      _logger.log('Error adding to queue: $e');
    }
  }

  /// Show player selector for add to queue
  void _addToQueueOn(BuildContext context) {
    final maProvider = context.read<MusicAssistantProvider>();
    final l10n = S.of(context)!;

    widget.onDismiss();

    GlobalPlayerOverlay.showPlayerSelectorForAction(
      contextHint: l10n.addToQueueOn,
      onPlayerSelected: (player) async {
        try {
          switch (widget.mediaType) {
            case ContextMenuMediaType.album:
              final album = widget.item as Album;
              final tracks = await maProvider.api?.getAlbumTracks(album.provider, album.itemId);
              if (tracks != null && tracks.isNotEmpty) {
                await maProvider.addTracksToQueue(player.playerId, tracks);
              }
              break;
            case ContextMenuMediaType.playlist:
              final playlist = widget.item as Playlist;
              final tracks = await maProvider.api?.getPlaylistTracks(playlist.provider, playlist.itemId);
              if (tracks != null && tracks.isNotEmpty) {
                await maProvider.addTracksToQueue(player.playerId, tracks);
              }
              break;
            case ContextMenuMediaType.track:
              final track = widget.item as Track;
              await maProvider.addTracksToQueue(player.playerId, [track]);
              break;
            case ContextMenuMediaType.artist:
            case ContextMenuMediaType.audiobook:
            case ContextMenuMediaType.podcast:
            case ContextMenuMediaType.podcastEpisode:
            case ContextMenuMediaType.radio:
              // These types don't support direct queue addition
              break;
          }
        } catch (e) {
          _logger.log('Error adding to queue: $e');
        }
      },
    );
  }

  /// Start radio instantly using selected player
  Future<void> _startRadio(BuildContext context) async {
    final maProvider = context.read<MusicAssistantProvider>();
    final player = maProvider.selectedPlayer;
    final l10n = S.of(context)!;

    if (player == null) {
      _showSnackBar(context, l10n.noPlayerSelected);
      return;
    }

    widget.onDismiss();

    try {
      switch (widget.mediaType) {
        case ContextMenuMediaType.artist:
          final artist = widget.item as Artist;
          await maProvider.playArtistRadio(player.playerId, artist);
          break;
        case ContextMenuMediaType.track:
          final track = widget.item as Track;
          await maProvider.playRadio(player.playerId, track);
          break;
        case ContextMenuMediaType.album:
        case ContextMenuMediaType.playlist:
        case ContextMenuMediaType.audiobook:
        case ContextMenuMediaType.podcast:
        case ContextMenuMediaType.podcastEpisode:
        case ContextMenuMediaType.radio:
          // These types don't support radio mode
          break;
      }
    } catch (e) {
      _logger.log('Error starting radio: $e');
    }
  }

  /// Show player selector for start radio
  void _startRadioOn(BuildContext context) {
    final maProvider = context.read<MusicAssistantProvider>();
    final l10n = S.of(context)!;

    widget.onDismiss();

    GlobalPlayerOverlay.showPlayerSelectorForAction(
      contextHint: l10n.startRadioOn(_itemName),
      onPlayerSelected: (player) async {
        try {
          switch (widget.mediaType) {
            case ContextMenuMediaType.artist:
              final artist = widget.item as Artist;
              await maProvider.playArtistRadio(player.playerId, artist);
              break;
            case ContextMenuMediaType.track:
              final track = widget.item as Track;
              await maProvider.playRadio(player.playerId, track);
              break;
            case ContextMenuMediaType.album:
            case ContextMenuMediaType.playlist:
            case ContextMenuMediaType.audiobook:
            case ContextMenuMediaType.podcast:
            case ContextMenuMediaType.podcastEpisode:
            case ContextMenuMediaType.radio:
              // These types don't support radio mode
              break;
          }
        } catch (e) {
          _logger.log('Error starting radio: $e');
        }
      },
    );
  }

  void _handleToggleFavorite() {
    widget.onDismiss();
    widget.onToggleFavorite?.call();
  }

  void _handleToggleLibrary() {
    widget.onDismiss();
    widget.onToggleLibrary?.call();
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Check if queue actions should be shown for this media type
  bool get _supportsQueue {
    return widget.mediaType == ContextMenuMediaType.album ||
        widget.mediaType == ContextMenuMediaType.playlist ||
        widget.mediaType == ContextMenuMediaType.track;
  }

  /// Check if radio actions should be shown for this media type
  bool get _supportsRadio {
    return widget.mediaType == ContextMenuMediaType.artist ||
        widget.mediaType == ContextMenuMediaType.track;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.adaptiveColorScheme ?? Theme.of(context).colorScheme;
    final l10n = S.of(context)!;

    // Calculate menu position
    const menuWidth = 185.0;
    final screenSize = MediaQuery.of(context).size;
    final viewPadding = MediaQuery.of(context).viewPadding;

    // Account for mini player and bottom nav bar.
    // On detail screens the nav bar hides and mini player drops to bottom edge.
    final isOnDetailScreen = context.read<ThemeProvider>().isOnDetailScreen;
    final bottomInset = isOnDetailScreen
        ? BottomSpacing.miniPlayerHeight + 22.0 + viewPadding.bottom
        : BottomSpacing.withMiniPlayer + viewPadding.bottom;

    // Position near the tap, but keep on screen
    double left = widget.position.dx - menuWidth / 2;

    // Keep menu on screen horizontally
    left = left.clamp(8.0, screenSize.width - menuWidth - 8);

    // Estimate menu height based on content
    double estimatedHeight = 8.0; // vertical padding (4 top + 4 bottom)
    if (widget.mediaType == ContextMenuMediaType.podcastEpisode) {
      estimatedHeight += 4 * 46.0; // 4 menu items
    } else {
      if (widget.showTopRow) estimatedHeight += 60.0; // icon button row
      estimatedHeight += 3 * 46.0; // Play on, Start radio, Start radio on
      if (widget.onToggleSort != null) {
        estimatedHeight += 1.0 + 32.0; // divider + header
        final sortCount = widget.mediaType == ContextMenuMediaType.podcast ? 4 : 2;
        estimatedHeight += sortCount * 42.0; // sort items
      }
      if (widget.onCycleView != null) {
        estimatedHeight += 1.0 + 32.0; // divider + header
        estimatedHeight += 3 * 42.0; // view mode items
      }
    }

    // Keep menu below the tap point but above the mini player
    final top = widget.position.dy.clamp(
      viewPadding.top + 8,
      screenSize.height - estimatedHeight - bottomInset,
    );

    return Stack(
      children: [
        // Dismiss on tap outside
        FadeTransition(
          opacity: _fadeAnimation,
          child: ModalBarrier(
            dismissible: true,
            onDismiss: widget.onDismiss,
            color: Colors.black12,
          ),
        ),
        // Menu with scale and fade animation
        Positioned(
          left: left,
          top: top,
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              alignment: Alignment.center,
              // Wrap in Theme to ensure FilledButton.tonal uses our colorScheme
              child: Theme(
                data: Theme.of(context).copyWith(colorScheme: colorScheme),
                child: SizedBox(
                  width: menuWidth,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    // Use lighter surface when adaptive colors are applied for better contrast
                    // Blend with white to make it subtly lighter than the background
                    color: widget.adaptiveColorScheme != null
                        ? Color.lerp(colorScheme.surface, Colors.white, 0.03)!
                        : colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Podcast episode menu - simplified options
                        if (widget.mediaType == ContextMenuMediaType.podcastEpisode) ...[
                          _buildMenuItem(
                            icon: Icons.play_arrow_rounded,
                            label: l10n.play,
                            onTap: () {
                              widget.onPlay?.call();
                              widget.onDismiss();
                            },
                            colorScheme: colorScheme,
                          ),
                          _buildMenuItem(
                            icon: Icons.speaker_group_outlined,
                            label: l10n.playOn,
                            onTap: () {
                              widget.onPlayOn?.call();
                              widget.onDismiss();
                            },
                            colorScheme: colorScheme,
                          ),
                          _buildMenuItem(
                            icon: Icons.playlist_add,
                            label: l10n.addToQueue,
                            onTap: () {
                              widget.onAddToQueue?.call();
                              widget.onDismiss();
                            },
                            colorScheme: colorScheme,
                          ),
                          Divider(height: 1, color: colorScheme.onSurface.withValues(alpha: 0.15)),
                          _buildMenuItem(
                            icon: Icons.info_outline,
                            label: l10n.viewDetails,
                            onTap: () {
                              widget.onViewDetails?.call();
                              widget.onDismiss();
                            },
                            colorScheme: colorScheme,
                          ),
                        ] else ...[
                        // Standard menu for other media types
                        // Top row: instant action buttons
                        if (widget.showTopRow) ...[
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                              // Play button
                              _buildIconButton(
                                icon: Icons.play_arrow_rounded,
                                label: l10n.play,
                                onTap: () => _play(context),
                                colorScheme: colorScheme,
                              ),
                              // Library button
                              if (widget.onToggleLibrary != null) ...[
                                const SizedBox(width: 12),
                                _buildIconButton(
                                  icon: Symbols.book_2,
                                  label: widget.isInLibrary ? l10n.inLibrary : l10n.addToLibrary,
                                  onTap: _handleToggleLibrary,
                                  colorScheme: colorScheme,
                                  isActive: widget.isInLibrary,
                                  fill: widget.isInLibrary ? 1 : 0,
                                ),
                              ],
                              // Favorite button
                              if (widget.onToggleFavorite != null) ...[
                                const SizedBox(width: 12),
                                _buildIconButton(
                                  icon: Icons.favorite,
                                  label: l10n.favorite,
                                  onTap: _handleToggleFavorite,
                                  colorScheme: colorScheme,
                                  isActive: widget.isFavorite,
                                  activeColor: Colors.red,
                                ),
                              ],
                            ],
                          ),
                        ),
                        Divider(height: 1, color: colorScheme.onSurface.withValues(alpha: 0.15)),
                      ],
                      // List items
                      _buildMenuItem(
                        icon: Icons.speaker_group_outlined,
                        label: l10n.playOn,
                        onTap: () => _playOn(context),
                        colorScheme: colorScheme,
                      ),
                      if (_supportsQueue) ...[
                        _buildMenuItem(
                          icon: Icons.playlist_add,
                          label: l10n.addToQueue,
                          onTap: () => _addToQueue(context),
                          colorScheme: colorScheme,
                        ),
                        _buildMenuItem(
                          icon: Icons.speaker_group_outlined,
                          label: l10n.addToQueueOn,
                          onTap: () => _addToQueueOn(context),
                          colorScheme: colorScheme,
                        ),
                      ],
                      if (_supportsRadio) ...[
                        _buildMenuItem(
                          icon: Icons.radio,
                          label: l10n.startRadio,
                          onTap: () => _startRadio(context),
                          colorScheme: colorScheme,
                        ),
                        _buildMenuItem(
                          icon: Icons.speaker_group_outlined,
                          label: l10n.startRadioOn(_itemName),
                          onTap: () => _startRadioOn(context),
                          colorScheme: colorScheme,
                        ),
                      ],
                      // Layout/sort controls (optional) - styled like library options menu
                      if (widget.onToggleSort != null || widget.onCycleView != null) ...[
                        Divider(height: 1, color: colorScheme.onSurface.withValues(alpha: 0.15)),
                        // Sort section
                        if (widget.onToggleSort != null) ...[
                          Padding(
                            padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 4),
                            child: Text(
                              'Sort',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                          ),
                          // Podcast-specific sort options
                          if (widget.mediaType == ContextMenuMediaType.podcast) ...[
                            _buildViewModeItem(
                              mode: 'newest',
                              label: l10n.newestFirst,
                              icon: Icons.arrow_downward,
                              isSelected: widget.sortOrder == 'newest',
                              onTap: () {
                                _setSortOrder('newest');
                              },
                              colorScheme: colorScheme,
                            ),
                            _buildViewModeItem(
                              mode: 'oldest',
                              label: l10n.oldestFirst,
                              icon: Icons.arrow_upward,
                              isSelected: widget.sortOrder == 'oldest',
                              onTap: () {
                                _setSortOrder('oldest');
                              },
                              colorScheme: colorScheme,
                            ),
                            _buildViewModeItem(
                              mode: 'alpha',
                              label: l10n.sortAlphabetically,
                              icon: Icons.sort_by_alpha,
                              isSelected: widget.sortOrder == 'alpha',
                              onTap: () {
                                _setSortOrder('alpha');
                              },
                              colorScheme: colorScheme,
                            ),
                            _buildViewModeItem(
                              mode: 'duration',
                              label: l10n.sortByDuration,
                              icon: Icons.timer_outlined,
                              isSelected: widget.sortOrder == 'duration',
                              onTap: () {
                                _setSortOrder('duration');
                              },
                              colorScheme: colorScheme,
                            ),
                          ] else ...[
                            // Default sort options (alpha/year)
                            _buildViewModeItem(
                              mode: 'alpha',
                              label: l10n.sortAlphabetically,
                              icon: Icons.sort_by_alpha,
                              isSelected: widget.sortOrder == 'alpha',
                              onTap: () {
                                if (widget.sortOrder != 'alpha') widget.onToggleSort!();
                                widget.onDismiss();
                              },
                              colorScheme: colorScheme,
                            ),
                            _buildViewModeItem(
                              mode: 'year',
                              label: l10n.sortByYear,
                              icon: Icons.calendar_today,
                              isSelected: widget.sortOrder != 'alpha',
                              onTap: () {
                                if (widget.sortOrder == 'alpha') widget.onToggleSort!();
                                widget.onDismiss();
                              },
                              colorScheme: colorScheme,
                            ),
                          ],
                        ],
                        // View section
                        if (widget.onCycleView != null) ...[
                          Divider(height: 1, color: colorScheme.onSurface.withValues(alpha: 0.15)),
                          Padding(
                            padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 4),
                            child: Text(
                              'View',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                          ),
                          _buildViewModeItem(
                            mode: 'list',
                            label: l10n.listView,
                            icon: Icons.view_list,
                            isSelected: widget.viewMode == 'list',
                            onTap: () {
                              _setViewMode('list');
                            },
                            colorScheme: colorScheme,
                          ),
                          _buildViewModeItem(
                            mode: 'grid2',
                            label: l10n.twoColumnGrid,
                            icon: Icons.grid_on,
                            isSelected: widget.viewMode == 'grid2',
                            onTap: () {
                              _setViewMode('grid2');
                            },
                            colorScheme: colorScheme,
                          ),
                          _buildViewModeItem(
                            mode: 'grid3',
                            label: l10n.threeColumnGrid,
                            icon: Icons.grid_view,
                            isSelected: widget.viewMode == 'grid3',
                            onTap: () {
                              _setViewMode('grid3');
                            },
                            colorScheme: colorScheme,
                          ),
                        ],
                      ],
                      ], // end else (standard menu)
                    ],
                  ),
                ),
              ),
            ),
            ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required ColorScheme colorScheme,
    bool isActive = false,
    Color? activeColor,
    Color? inactiveColor,
    double? fill,
  }) {
    final iconColor = isActive
        ? (activeColor ?? colorScheme.primary)
        : (inactiveColor ?? Colors.white70);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 46,
          height: 46,
          child: FilledButton.tonal(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Icon(
              icon,
              color: iconColor,
              size: 23,
              fill: fill,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: colorScheme.onSurface,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
          maxLines: 1,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required ColorScheme colorScheme,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Set view mode and cycle through until we reach the target
  void _setViewMode(String targetMode) {
    if (widget.viewMode == targetMode) {
      widget.onDismiss();
      return;
    }
    // Cycle until we reach target mode
    String current = widget.viewMode ?? 'grid2';
    while (current != targetMode) {
      widget.onCycleView!();
      // Simulate the cycle logic
      switch (current) {
        case 'grid2':
          current = 'grid3';
          break;
        case 'grid3':
          current = 'list';
          break;
        default:
          current = 'grid2';
      }
    }
    widget.onDismiss();
  }

  /// Set sort order and cycle through until we reach the target (for podcasts)
  void _setSortOrder(String targetOrder) {
    if (widget.sortOrder == targetOrder) {
      widget.onDismiss();
      return;
    }
    // Cycle until we reach target order
    String current = widget.sortOrder ?? 'newest';
    while (current != targetOrder) {
      widget.onToggleSort!();
      // Simulate the cycle logic: newest -> oldest -> alpha -> duration -> newest
      switch (current) {
        case 'newest':
          current = 'oldest';
          break;
        case 'oldest':
          current = 'alpha';
          break;
        case 'alpha':
          current = 'duration';
          break;
        default:
          current = 'newest';
      }
    }
    widget.onDismiss();
  }

  Widget _buildViewModeItem({
    required String mode,
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required ColorScheme colorScheme,
  }) {
    return Material(
      color: isSelected ? colorScheme.primary.withOpacity(0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? colorScheme.primary : colorScheme.onSurface.withOpacity(0.7),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
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
