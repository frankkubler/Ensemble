# Copilot Instructions — Ensemble

## Project Overview

**Ensemble** is an unofficial, community-built Android mobile client for [Music Assistant](https://music-assistant.io/), built with **Flutter/Dart**.  
It lets users stream their music library directly to their phone (via the Sendspin protocol) or control playback on any connected speaker.  
The project was initiated from `CollotsSpot/Ensemble` and is developed with AI-assisted tooling (Claude Code, Gemini CLI).

Current version: `3.0.6+58` — target platform: **Android** (minSdk 23, Android 5.0+).  
iOS support is **not active** (`ios: false` in launcher icons config).

---

## Architecture

### State Management

- **Pattern**: `provider` package (`^6.1.1`) — no Riverpod, no Bloc.
- Central state lives in `lib/providers/music_assistant_provider.dart` (~283 KB — the main god-provider).
- Supporting providers: `ConnectionProvider`, `NavigationProvider`, `LocaleProvider`, `SleepTimerProvider`.
- Always use `context.read<T>()` for one-shot calls, `context.watch<T>()` or `Consumer` for reactive UI.

### Directory Structure

```
lib/
├── constants/        # App-wide constants (colors, strings, enums)
├── database/         # Drift ORM schema & DAOs
├── l10n/             # ARB localisation files (flutter_localizations)
├── models/           # Pure Dart data models (no business logic)
├── providers/        # ChangeNotifier providers (state)
├── screens/          # Full-page UI (one file per screen)
├── services/         # Business logic & external integrations
│   ├── audio/        # Audio service handlers
│   └── auth/         # Authentication helpers
├── theme/            # MaterialYou / dynamic color theming
├── utils/            # Pure utility functions
└── widgets/          # Reusable UI components
```

### Key Services

| File | Responsibility |
|---|---|
| `music_assistant_api.dart` | WebSocket + HTTP client for Music Assistant API (~129 KB) |
| `music_assistant_provider.dart` | Central app state, player management, library cache |
| `sendspin_service.dart` | PCM audio streaming via Sendspin protocol (~24 KB) |
| `pcm_audio_player.dart` | Low-level PCM playback via `flutter_pcm_sound` |
| `cache_service.dart` | In-memory + Drift SQLite caching layer (~33 KB) |
| `sync_service.dart` | Background library synchronisation (~30 KB) |
| `settings_service.dart` | All user preferences via `SharedPreferences` (~43 KB) |
| `metadata_service.dart` | Track/album/artist metadata enrichment (~33 KB) |
| `connection_provider.dart` | WebSocket connection lifecycle & reconnection logic |

---

## Communication with Music Assistant

- Protocol: **WebSocket** (`web_socket_channel ^2.4.0`) for real-time events.
- HTTP (`http ^1.1.0`) for REST calls (library browsing, image fetching).
- The server URL is stored via `SecureStorageService` (uses `flutter_secure_storage`).
- **Never hardcode** server URLs or credentials — always read from `SecureStorageService` or `SettingsService`.
- Music Assistant API version requirement: **v2.7.0 beta 20 or later**.

---

## Audio Pipeline

```
Music Assistant Server
        │
        ▼
  SendspinService          ← Receives raw PCM stream over WebSocket
        │
        ▼
  PcmAudioPlayer           ← flutter_pcm_sound (low-level PCM output)
        │
        ▼
  AudioServiceHandler      ← audio_service (background + media notifications)
        │
        ▼
  Android MediaSession     ← Exposes controls to notification shade & Android Auto
```

- Local playback uses `just_audio` for standard audio formats and `flutter_pcm_sound` for the Sendspin stream.
- Background playback is mandatory — always use `audio_service` callbacks, never raw audio calls outside the handler.
- PCM format: typically 44100 Hz / 16-bit / stereo — check `SendspinService` for negotiated parameters.

---

## Android Auto Integration

Android Auto support is the primary active development area. Key rules:

- The **browsing delegate** (`AndroidAutoBrowsingDelegate`) handles all media browser tree construction — do not mix browsing logic into the provider.
- During an AA session (`isAndroidAutoSession == true`), **always** route playback through the **built-in player** unless the user explicitly overrides via `userOverridePlayer`.
- Use `userOverridePlayer` flag to respect user-initiated player selection during an AA session.
- AA images must be resolved via the `ImagePrefetchService` — do not call the MA API directly from the media browser service.
- A-Z index headers are added for lists > 50 items to improve car display navigation.
- Artwork must be a `Bitmap` (not a URL) when returned to AA `MediaItem` — always resolve before building the `MediaItem`.

---

## Database (Drift / SQLite)

- ORM: `drift ^2.22.0` with `drift_flutter 0.2.0`.
- Schema defined in `lib/database/`.
- Run code generation after any schema change:
  ```bash
  dart run build_runner build --delete-conflicting-outputs
  ```
- `DatabaseService` wraps all DAO access — never call DAOs directly from UI or providers.

---

## Theming

- **Material You** dynamic theming via `dynamic_color ^1.6.8`.
- Album-art-based color palettes use `palette_generator` with **isolate-based** decoding (uses the `image` package, not `dart:ui` — safe in isolates).
- Light/Dark mode is system-aware; manual override stored in `SettingsService`.
- Always use `Theme.of(context).colorScheme.*` — never hardcode hex colors in widgets.

---

## Localisation

- Flutter's `flutter_localizations` + `intl ^0.20.0`.
- ARB files in `lib/l10n/`.
- Config: `l10n.yaml` at project root.
- After adding new keys, run:
  ```bash
  flutter gen-l10n
  ```
- Access strings via `AppLocalizations.of(context)!.myKey` — never use raw string literals in UI.

---

## Coding Conventions

- **Dart style**: follow `analysis_options.yaml` (flutter_lints). No lint suppressions without a comment explaining why.
- **Async**: use `async/await` — avoid raw `.then()` chains.
- **Error handling**: use `ErrorHandler` service for user-facing errors; use `DebugLogger` for internal logging.
- **Retry logic**: use `RetryHelper` for any network call that may fail transiently.
- **Null safety**: the project uses sound null safety (Dart SDK `>=3.0.0`). Avoid `!` force-unwraps without a guard.
- **Immutable models**: models in `lib/models/` should be immutable where possible (`final` fields, `copyWith`).
- **No BuildContext across async gaps**: store what you need before `await`, or check `mounted` after.

---

## Commit Message Convention

Follow **Conventional Commits**:

```
feat: add X feature
fix: resolve Y bug
chore: bump version / update deps
refactor: restructure Z without behaviour change
docs: update README or instructions
test: add/update tests
```

---

## Known Open Issues (April 2026)

- **`fix/podcast-audiobook-player-issues`** branch: podcast and audiobook player bugs — do not regress playback state management in these flows.
- **`Android-auto-sound-resolution`** branch: Android Auto audio routing/resolution is still unstable — changes to `SendspinService` or `PcmAudioPlayer` must be tested in AA context.

---

## Out of Scope

- **iOS**: not targeted, do not add iOS-specific code.
- **Play Store**: app is distributed as APK only (Fastlane for build/sign). Do not add Play Store billing or in-app-purchase code.
- **Web/Desktop**: Flutter targets are Android only.

---

## Build & Run

```bash
# Install dependencies
flutter pub get

# Generate code (Drift + l10n)
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n

# Run on device
flutter run

# Build release APK
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

Minimum Flutter SDK: `>=3.0.0`.
