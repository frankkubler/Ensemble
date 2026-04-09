# WebRTC Migration Status - 2026-04-09

## Purpose

This document captures the current state of Ensemble's WebRTC migration so work can resume later without redoing the analysis.

It covers:

- target architecture
- implementation lots
- what is already implemented
- what remains to do
- compatibility constraints
- runtime risks and validation notes

## Current Goal

The current product goal is:

1. Keep direct connection fully functional.
2. Make WebRTC remote access usable as a first-class mode.
3. Remove the requirement for the user to manually enter an external server address.
4. Gradually reduce client dependence on `serverUrl` for remote mode.

This is being done incrementally to avoid regressions in direct mode, local playback, and Android Auto.

## Non-Negotiable Constraint

Direct mode must remain a first-class connection path.

That means:

- no silent replacement of direct mode by WebRTC
- no regression in login flow for direct mode
- no regression in reconnect flow for direct mode
- no regression in Sendspin/direct proxy behavior when direct mode is selected

The selected mode must remain explicit and respected.

## Architecture Summary

### WebRTC pieces currently in place

- `lib/services/remote/signaling_client.dart`
- `lib/services/remote/webrtc_connection_manager.dart`
- `lib/services/remote/webrtc_api_transport.dart`
- `lib/services/remote/webrtc_sendspin_transport.dart`
- `lib/services/remote/webrtc_shared_session.dart`
- `lib/services/remote/ma_connection_transport.dart`
- `lib/services/remote/sendspin_transport.dart`

### Existing behavior already working

- MA control path can go through WebRTC data channel.
- MA authentication can complete over the MA API transport.
- Sendspin can run over WebRTC data channel.
- Shared WebRTC session is used for both MA API and Sendspin.
- Remote ID normalization is implemented.
- Signaling payloads were aligned with the official MA mobile app behavior.

### Remaining architectural problem

Even after WebRTC is active, the app still historically depended on `serverUrl` for:

- startup/bootstrap decisions
- relative media URL expansion
- imageproxy URLs
- preview/flow URL construction
- sendspin proxy URL generation

The implemented lots below address this progressively.

## Lots Overview

### Lot 1

Goal: make WebRTC a valid startup/reconnect profile without requiring a manually entered server URL.

### Lot 2

Goal: centralize HTTP endpoint construction and remove manual URL concatenation from API/provider code.

### Lot 3

Goal: harden remaining playback and Sendspin behaviors when no resolvable HTTP base exists.

### Future server-side lot

Goal: reduce or eliminate remaining HTTP dependency for remote assets.

This future lot is not fully implementable client-side only.

## Implemented Lots

## Lot 1 - Implemented

### Goal

Allow the app to:

- start from a WebRTC profile
- reconnect from a WebRTC profile
- keep direct mode unchanged

### Files changed

- `lib/services/settings_service.dart`
- `lib/providers/connection_provider.dart`
- `lib/providers/music_assistant_provider.dart`
- `lib/main.dart`
- `lib/screens/login_screen.dart`

### What was implemented

#### Settings profile helpers

Added profile readiness helpers in `SettingsService`:

- direct connection profile detection
- WebRTC connection profile detection
- active connection profile detection based on preferred mode

#### Connection provider changes

`ConnectionProvider` now understands two logical profiles:

- direct profile
- WebRTC profile

It no longer requires an explicit server URL when WebRTC mode is selected and valid.

A bootstrap placeholder URL is used internally only to satisfy existing API construction until deeper URL decoupling is complete.

#### Bootstrap changes

`main.dart` no longer decides startup based only on `serverUrl`.

The app can now enter Home/start connection when an active WebRTC profile exists.

#### Provider initialization changes

`MusicAssistantProvider._initialize()` now restores auth and attempts connection when any active profile exists, not just when `serverUrl` exists.

#### Login flow changes

The login screen now behaves differently by mode:

- direct mode: server address required
- WebRTC mode: Remote ID required, server address optional

This preserves direct mode while allowing WebRTC-first login.

### Validation status

- targeted static validation passed on modified files
- user confirmed Lot 1 behavior worked in practice

### Important limitation

Lot 1 changes bootstrap and profile readiness.

It does not remove deeper HTTP dependency for assets and relative media URLs.

## Lot 2 - Implemented

### Goal

Centralize all remaining HTTP endpoint construction so the app stops manually rebuilding URLs from `_serverUrl` in multiple places.

### Files changed

- `lib/services/remote/http_endpoint_resolver.dart` (new)
- `lib/services/music_assistant_api.dart`
- `lib/providers/music_assistant_provider.dart`
- `lib/services/sendspin_service.dart`

### What was implemented

#### New resolver

Added `HttpEndpointResolver` as a single source of truth for:

- HTTP base URL normalization
- absolute URL construction from relative paths
- flow URL generation
- preview URL generation
- imageproxy URL generation
- imageproxy URL rebuilding from existing query strings
- Sendspin proxy WebSocket URL generation

#### Placeholder protection

The resolver refuses to build HTTP URLs from the internal WebRTC bootstrap placeholder host.

This prevents the app from generating obviously invalid HTTP URLs when WebRTC is active without a real HTTP base.

#### API migration

`MusicAssistantAPI` now uses the resolver for:

- `getCurrentStreamUrl()`
- `getStreamUrl()`
- `getImageUrl()`

This removes manual duplication of HTTP/HTTPS/port logic in those paths.

#### Provider migration

`MusicAssistantProvider` now uses the resolver for:

- relative URL expansion during playback
- imageproxy rebuilds from current media events
- imageproxy rebuilds for notification metadata

#### Sendspin migration

`SendspinService` now uses the resolver for external `/sendspin` proxy URL construction.

### Validation status

- targeted static validation passed on modified files

### Important limitation

Lot 2 centralizes and hardens URL construction.

It does not eliminate the need for an HTTP-capable base when the app still needs:

- imageproxy
- flow/preview endpoints
- any remaining non-WebRTC asset path

## Lot 3 - Implemented (partial hardening)

### Goal

Prevent invalid fallback behavior in remote mode when no resolvable HTTP base exists.

### Files changed

- `lib/providers/music_assistant_provider.dart`
- `lib/services/sendspin_service.dart`

### What was implemented

#### Sendspin connection hardening

`_connectViaSendspin()` no longer fails too early on missing direct `serverUrl` when WebRTC mode is active.

WebRTC Sendspin remains allowed to proceed.

#### Playback hardening

When Sendspin emits a play command with a relative path and no resolvable HTTP base exists:

- metadata is still updated
- PCM/WebRTC remains authoritative
- the app skips invalid local URL playback instead of trying to play a broken relative path

#### External proxy hardening

`SendspinService.connect()` now skips external proxy attempts when no resolvable external URL exists, instead of trying to connect using an empty string.

### Validation status

- targeted static validation passed on modified files

## What Is Still Not Solved

The following is still unresolved and is expected:

### 1. Remote assets still ultimately need an HTTP-capable path

The client is now better isolated from `serverUrl`, but remote mode still has functional dependence on HTTP for some paths.

Examples:

- artwork via imageproxy
- preview/flow URLs when used outside pure Sendspin WebRTC flow
- any feature consuming direct HTTP media/asset paths from MA

### 2. Fully WebRTC-native remote assets are not implemented

There is no dedicated WebRTC assets channel yet.

That means there is still no pure client-side solution to eliminate all HTTP dependence.

### 3. Some strategy code still legitimately uses `_serverUrl`

Remaining `_serverUrl` usages are acceptable for now in places that still choose between direct/local/proxy strategies.

Those are not the same problem as manual string concatenation for assets.

## Recommended Next Steps

### Client-side next step

Perform runtime validation on device for:

1. direct mode startup
2. WebRTC mode startup without manual server URL
3. app resume / reconnect
4. Sendspin over WebRTC
5. local playback metadata updates
6. Android Auto session behavior
7. artwork loading behavior in WebRTC mode

### Product/architecture next step

Decide between two end states:

#### Option A - No external URL entered by user

Keep an HTTP asset path behind the scenes, but stop requiring the user to know it.

This is largely enabled by the implemented work.

#### Option B - Fully remote, minimal HTTP dependence

Add a new server-supported remote asset mechanism, most likely one of:

- a dedicated WebRTC assets data channel
- a remote access relay that resolves artwork/media endpoints from Remote ID

This requires server-side work outside the current client refactor.

## Runtime Validation Status

### Confirmed during this session

- WebRTC connection works with normalized Remote ID
- Remote ID also works when user enters dashes
- targeted static checks were clean after each implementation step

### Not fully validated in this session

- full Flutter build after all lots
- real device regression test for direct mode after lots 1 to 3
- full Android Auto remote scenario after latest refactors
- artwork behavior in all screens without a resolvable HTTP base

## Files Touched During This Migration Work

Core profile/bootstrap changes:

- `lib/services/settings_service.dart`
- `lib/providers/connection_provider.dart`
- `lib/providers/music_assistant_provider.dart`
- `lib/main.dart`
- `lib/screens/login_screen.dart`

HTTP decoupling and hardening:

- `lib/services/remote/http_endpoint_resolver.dart`
- `lib/services/music_assistant_api.dart`
- `lib/services/sendspin_service.dart`

Existing WebRTC stack involved in the final architecture:

- `lib/services/remote/signaling_client.dart`
- `lib/services/remote/webrtc_connection_manager.dart`
- `lib/services/remote/webrtc_api_transport.dart`
- `lib/services/remote/webrtc_sendspin_transport.dart`
- `lib/services/remote/webrtc_shared_session.dart`

## Handoff Notes

If work resumes later, start by checking:

1. whether direct mode still passes runtime smoke tests
2. whether WebRTC startup still works without manual server URL
3. whether any screen still assumes imageproxy always resolves
4. whether Android Auto artwork path still requires extra adaptation

If the next task is purely client-side, continue with runtime validation and cleanup.

If the next task is to remove the final HTTP dependency, plan server-side work first.
