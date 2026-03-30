<div align="center">
  <img src="assets/images/ensemble_logo.png" alt="Ensemble Logo" height="200">

  [![GitHub release](https://img.shields.io/badge/Release-v3.0.4-blue?style=for-the-badge&logo=github)](https://github.com/CollotsSpot/Ensemble/releases)
  [![GitHub Downloads](https://img.shields.io/github/downloads/CollotsSpot/Ensemble/latest/total?style=for-the-badge&logo=android&label=APK%20Downloads&color=green)](https://github.com/CollotsSpot/Ensemble/releases/latest)
  [![License: MIT](https://img.shields.io/badge/License-MIT-purple.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)
  [![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub-EA4AAA?style=for-the-badge&logo=GitHub%20Sponsors&logoColor=white)](https://github.com/sponsors/CollotsSpot)
  [![Ko-fi](https://img.shields.io/badge/Ko--fi-FF5E5B?style=for-the-badge&logo=Ko-fi&logoColor=white)](https://ko-fi.com/collotsspot)

---

  <p><strong>An unofficial mobile client for Music Assistant</strong></p>
  <p>Stream your music library directly to your phone, or control playback on any connected speaker.</p>
</div>

---

## Disclaimer

**Ensemble is an unofficial, community-built mobile client for Music Assistant. It is not affiliated with, endorsed by, or supported by the Music Assistant project or its developers.**

This application was built with AI-assisted development using **Claude Code** and **Gemini CLI**.

---

## Also See

**[Ensemble TV](https://github.com/CollotsSpot/ensemble-tv)** - A simple Android TV client for Music Assistant that displays what's currently playing on your TV with remote control support.

---

## Features

### Local Playback
- **Stream to Your Phone** - Play music from your Music Assistant library directly on your mobile device via Sendspin protocol
- **Background Playback** - Music continues playing when the app is minimized
- **Media Notifications** - Control playback from your notification shade with album art display
- **Instant Response** - Pause/resume in ~300ms

### Remote Control
- **Multi-Player Support** - Control any speaker or device connected to Music Assistant
- **Device Selector** - Swipe down on mini player to reveal all your devices
- **Multi-Room Grouping** - Long-press any player to sync it with the current player
- **Full Playback Controls** - Play, pause, skip, seek, and adjust volume
- **Volume Precision Mode** - Hold the volume slider for fine-grained control with haptic feedback
- **Power Control** - Turn players on/off directly from the mini player

### Queue Management
- **View & Manage Queue** - See upcoming tracks in the playback queue
- **Drag to Reorder** - Instant drag handles for reordering tracks
- **Swipe left to Delete** - Remove tracks with a simple swipe gesture
- **Swipe right to play next** - Move tracks with a simple swipe gesture

### Home Screen
- **Customizable Rows** - Toggle and reorder: Recently Played, Discover Artists, Discover Albums
- **Favorites Rows** - Optional rows for Favorite Albums, Artists, Tracks, Playlists, and Radio Stations
- **Adaptive Layout** - Rows scale properly for different screen sizes and aspect ratios
- **Pull to Refresh** - Refresh content with a simple pull gesture

### Library
- **Music** - Browse artists, albums, playlists, and tracks from all your music sources
- **Radio Stations** - Browse and play radio stations with list or grid view
- **Podcasts** - Browse podcasts, view episodes with descriptions and publish dates
- **Audiobooks** - Browse by title, series, or author with progress tracking
- **Favorites Filter** - Toggle to show only your favorite items
- **Providers Filter** - Toggle to show only specific provider items
- **Letter Scrollbar** - Fast navigation through long lists
- **Provider Icons** - Provider icons on library covers

### Search
- **Universal Search** - Find music, podcasts, radio stations, playlists, and audiobooks
- **Fuzzy Matching** - Typo-tolerant search (e.g., "beetles" finds "Beatles")
- **Smart Scoring** - Results ranked by relevance with colored type indicators
- **Search History** - Quickly access your recent searches
- **Quick Actions** - Long-press any result to add to queue or play next

### Audiobooks
- **Chapter Navigation** - Jump between chapters with timestamp display
- **Progress Tracking** - Track your listening progress across sessions
- **Continue Listening** - Pick up where you left off
- **Mark as Finished/Unplayed** - Manage your reading progress
- **Series Support** - View audiobooks organized by series with collage cover art

### Podcasts
- **Episode Browser** - View full episode list with artwork and descriptions
- **Skip Controls** - Skip forward/backward during playback
- **High-Resolution Artwork** - Fetched via iTunes for best quality

### Android Auto
- **Media Browsing** - Browse your library from your car's display with categories for Home, Music, Audiobooks, Podcasts, and Radio
- **Voice Search** - Find and play tracks using voice commands
- **Full Playback Controls** - Play, pause, and skip from your car's head unit
- **Album Art & Metadata** - Track info and artwork displayed on your car's screen
- **Smart Queueing** - Tap any track in an album or playlist to play from that point with the full queue

### Smart Features
- **Instant App Restore** - App loads instantly with cached library data while syncing in background
- **Auto-Reconnect** - Automatically reconnects when connection is lost
- **Offline Browsing** - Browse your cached library even when disconnected
- **Hero Animations** - Smooth transitions between screens
- **Welcome Screen** - Guided onboarding for first-time users

### Theming
- **Material You** - Dynamic theming based on your device's wallpaper
- **Adaptive Colors** - Album artwork-based color schemes
- **Light/Dark Mode** - System-aware or manual theme selection

## Screenshots

<div align="center">
  <img src="assets/screenshots/1.png?v=4" alt="Screenshot 1" width="150">
  <img src="assets/screenshots/2.png?v=4" alt="Screenshot 2" width="150">
  <img src="assets/screenshots/3.png?v=4" alt="Screenshot 3" width="150">
  <img src="assets/screenshots/4.png?v=4" alt="Screenshot 4" width="150">
  <img src="assets/screenshots/5.png?v=4" alt="Screenshot 5" width="150">
  <img src="assets/screenshots/6.png?v=4" alt="Screenshot 6" width="150">
  <img src="assets/screenshots/7.png?v=4" alt="Screenshot 7" width="150">
  <img src="assets/screenshots/8.png?v=4" alt="Screenshot 8" width="150">
  <img src="assets/screenshots/9.png?v=4" alt="Screenshot 9" width="150">
  <img src="assets/screenshots/10.png?v=4" alt="Screenshot 10" width="150">
  <img src="assets/screenshots/11.png?v=4" alt="Screenshot 11" width="150">
  <img src="assets/screenshots/12.png?v=4" alt="Screenshot 12" width="150">
</div>

## Download

Download the latest release from the [Releases page](https://github.com/CollotsSpot/Ensemble/releases).

## Setup

1. Launch the app
2. Enter your Music Assistant server URL
3. Connect to your server
4. Start playing! Music plays on your phone by default, or swipe down on the mini player to choose a different player.

### Finding Your Server URL

**Important:** You need the **Music Assistant** URL, not your Home Assistant URL.

To find the correct URL:
1. Open Music Assistant web UI
2. Go to **Settings** > **About**
3. Look for **Base URL** (e.g., `http://192.168.1.100:8095`)

### Home Assistant Add-on Users

If you run Music Assistant as a Home Assistant add-on:
- Use the IP address of your Home Assistant server
- Do **not** use your Home Assistant URL or ingress URL

### Android Auto

Since Ensemble is not installed from the Play Store, you need to enable unknown sources in Android Auto:

1. Open **Android Auto** settings on your phone
2. Tap the **Version** number at the bottom 10 times to enable developer mode
3. Tap the three-dot menu and open **Developer settings**
4. Enable **Unknown sources**
5. Connect your phone to your car via USB or wirelessly
6. Ensemble will appear in Android Auto's app list

### Remote Access

For access outside your home network, you'll need to expose Music Assistant through a reverse proxy (e.g., Traefik, Nginx Proxy Manager, Cloudflare Tunnel).

## Requirements

- Music Assistant server (v2.7.0 beta 20 or later recommended)
- Network connectivity to your Music Assistant server
- Android device (Android 5.0+)
- Audiobookshelf provider configured in Music Assistant (for audiobook features)

## Sponsors

A huge thank you to my sponsors! 💖

<a href="https://github.com/pcsokonay"><img src="https://github.com/pcsokonay.png" width="60px" alt="pcsokonay" /></a>
<a href="https://github.com/githubchb"><img src="https://github.com/githubchb.png" width="60px" alt="githubchb" /></a>

## License

MIT License

---

## For Developers

<details>
<summary>Build from Source</summary>

### Prerequisites
- Flutter SDK (>=3.0.0)
- Dart SDK

### Build Instructions

1. Clone the repository
```bash
git clone https://github.com/CollotsSpot/Ensemble.git
cd Ensemble
```

2. Install dependencies
```bash
flutter pub get
```

3. Generate launcher icons
```bash
flutter pub run flutter_launcher_icons
```

4. Build APK
```bash
flutter build apk --release
```

The APK will be available at `build/app/outputs/flutter-apk/app-release.apk`

</details>

<details>
<summary>Technologies Used</summary>

- **Flutter** - Cross-platform mobile framework
- **audio_service** - Background playback and media notifications
- **web_socket_channel** - WebSocket communication with Music Assistant
- **provider** - State management
- **cached_network_image** - Image caching
- **shared_preferences** - Local settings storage

</details>
