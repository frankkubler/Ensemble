# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ensemble is an unofficial Flutter mobile client for Music Assistant (MA). It connects to a Music Assistant server to stream music to the phone (builtin/local player) or control remote speakers. The app supports Android Auto for car integration.

**Key Tech Stack:**
- Flutter 3.38.0 (master channel)
- Dart SDK >=3.0.0
- `provider` for state management
- `audio_service` + `just_audio` for background audio playback
- `web_socket_channel` for MA WebSocket communication
- Drift for local SQLite database (library caching, profiles, recently played)
- Sendspin protocol for streaming audio from MA server to local device

## Build Commands

```bash
# Install dependencies
flutter pub get

# Generate code (Drift database, localizations)
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n

# Generate launcher icons
flutter pub run flutter_launcher_icons

# Analyze code
flutter analyze

# Build APK (release)
flutter build apk --release

# Build APK (debug)
flutter build apk --debug
```

APK output: `build/app/outputs/flutter-apk/app-release.apk`

## Architecture

### Core Provider Pattern
`MusicAssistantProvider` (lib/providers/music_assistant_provider.dart) is the central state management class. It's a facade that coordinates:
- Connection state (WebSocket to MA server)
- Player state (selected player, playback controls)
- Library state (artists, albums, tracks, playlists, audiobooks, podcasts, radio)
- Sync state (library caching via `SyncService`)

The provider is initialized in `main.dart` and injected via `ChangeNotifierProvider` at the app root.

### Audio Architecture
```
main.dart
  └── AudioService.init() → MassivAudioHandler (global singleton)
        ├── Android Auto media browsing (getChildren, playFromMediaId)
        ├── Media notifications and lockscreen controls
        └── Local playback via just_audio (Sendspin streaming)

MassivAudioHandler (lib/services/audio/massiv_audio_handler.dart)
  ├── Implements BaseAudioHandler, QueueHandler, SeekHandler
  ├── Manages Android Auto browse hierarchy (root → categories → items)
  ├── Coordinates with MusicAssistantProvider for queue management
  └── Handles Sendspin audio streaming for local playback
```

### Sendspin Streaming
Local playback uses the Sendspin protocol (MA 2.7.0b20+). `SendspinService` establishes a WebSocket connection to receive PCM audio data, which is played through `PcmAudioPlayer` using `flutter_pcm_sound`. The flow:
1. User selects builtin player
2. `SendspinService.connect()` establishes WebSocket
3. MA server streams raw PCM audio
4. `PcmAudioPlayer` renders to device speakers

### Data Flow
```
MusicAssistantAPI (WebSocket) → MusicAssistantProvider → UI
                                     ↓
                              SyncService → DatabaseService (Drift)
                                     ↓
                              CacheService (in-memory caching)
```

### Key Files
- `lib/main.dart` - App entry, initializes AudioService before runApp
- `lib/providers/music_assistant_provider.dart` - Central state (~260KB, contains most business logic)
- `lib/services/music_assistant_api.dart` - WebSocket protocol for MA server communication
- `lib/services/audio/massiv_audio_handler.dart` - AudioService handler with Android Auto support
- `lib/services/sync_service.dart` - Background library sync and caching
- `lib/services/sendspin_service.dart` - WebSocket streaming for local playback
- `lib/services/pcm_audio_player.dart` - Raw PCM audio rendering
- `android/app/src/main/kotlin/.../MainActivity.kt` - Volume button interception for remote player control

### Media ID Scheme (Android Auto)
Media IDs use `|` as separator: `cat|albums`, `playlist|lib|5`, `track|lib|7|plist|lib|5`

### Localization
App uses Flutter's built-in localization. ARB files in `lib/l10n/`. Run `flutter gen-l10n` after edits.

### Drift Database
Database schema in `lib/database/database.dart`. Generated code in `database.g.dart`. Run `dart run build_runner build --delete-conflicting-outputs` after schema changes.

## Key Patterns

### Android Auto Browsing
`MassivAudioHandler.getChildren()` handles browse requests. Root returns category items (Favorites, Playlists, Albums, etc.). Each category drills down to playable items. When playing, queue is pre-populated in `_trackQueueCache` for instant queue-based playback.

### Player Selection
MA supports multiple players (builtin, Cast devices, speakers). `MusicAssistantProvider.selectedPlayer` tracks current player. Local playback uses the "builtin" player with Sendspin streaming. Remote players are controlled via MA WebSocket commands.

### Volume Control
- Local player: Volume controlled via `just_audio` (device volume)
- Remote players: Volume sent to MA server, mirrored to system volume via `MainActivity.kt` MethodChannel for lockscreen volume HUD

### Image URLs
`provider.getImageUrl(item, size: 256)` returns sized image URLs. Images are cached via `cached_network_image`.

### Debugging
`DebugLogger` (lib/services/debug_logger.dart) provides timestamped logging. Enable via settings to see detailed logs.