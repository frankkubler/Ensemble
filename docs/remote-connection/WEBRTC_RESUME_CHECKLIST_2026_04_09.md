# WebRTC Resume Checklist - 2026-04-09

## Current State

- Direct mode must continue to work.
- WebRTC mode now supports startup and reconnect without requiring a manually entered server URL.
- HTTP endpoint construction for flow, preview, imageproxy, and `/sendspin` is now centralized.
- Playback and Sendspin paths have been hardened when no resolvable HTTP base exists.

Main reference document:

- `docs/remote-connection/WEBRTC_MIGRATION_STATUS_2026_04_09.md`

## What Has Been Implemented

### Lot 1

- WebRTC connection profile support in settings/bootstrap.
- Startup no longer depends only on `serverUrl`.
- Login supports WebRTC without requiring server address.
- Direct mode kept intact.

### Lot 2

- Added centralized HTTP resolver.
- Removed manual URL rebuilding for:
  - `flow`
  - `preview`
  - `imageproxy`
  - `/sendspin`

### Hardening After Lot 2

- Skip invalid local URL playback when Sendspin WebRTC/PCM is authoritative.
- Skip invalid external Sendspin proxy attempts when no resolvable URL exists.

## Files Most Relevant For Resume

Profile/bootstrap:

- `lib/services/settings_service.dart`
- `lib/providers/connection_provider.dart`
- `lib/providers/music_assistant_provider.dart`
- `lib/main.dart`
- `lib/screens/login_screen.dart`

HTTP decoupling:

- `lib/services/remote/http_endpoint_resolver.dart`
- `lib/services/music_assistant_api.dart`
- `lib/services/sendspin_service.dart`

WebRTC stack:

- `lib/services/remote/signaling_client.dart`
- `lib/services/remote/webrtc_connection_manager.dart`
- `lib/services/remote/webrtc_api_transport.dart`
- `lib/services/remote/webrtc_sendspin_transport.dart`
- `lib/services/remote/webrtc_shared_session.dart`

## Immediate Validation Checklist

Run these first on device:

1. Direct mode login and reconnect.
2. WebRTC mode login without server URL.
3. App relaunch with saved WebRTC profile.
4. Sendspin playback over WebRTC.
5. Background/resume reconnect.
6. Android Auto session attach/detach.
7. Artwork loading in key screens.

## Known Remaining Gap

The client is now much less coupled to `serverUrl`, but remote mode still does not fully eliminate HTTP dependence for all assets.

What remains structurally unresolved:

- artwork/image delivery without HTTP relay
- any remaining feature that still expects MA HTTP asset endpoints

This is a server-side/product architecture question, not only a client refactor.

## Recommended Next Task

Choose one:

1. Runtime validation and bug fixing after the current refactor.
2. Introduce a distinct remote HTTP asset endpoint model for remote mode.
3. Design a server-backed remote asset solution to reduce HTTP dependence further.

## Guardrails

- Do not break direct mode.
- Do not silently switch users from direct to WebRTC.
- Keep `preferredConnectionMode` authoritative.
- Treat Sendspin WebRTC as authoritative for remote builtin playback.
