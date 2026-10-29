# Matcha Music — c12n rebuild

A clean-room SwiftUI music player for your own servers and your own files.
Connect a **Subsonic / Navidrome**, **Jellyfin** or **Plex** server, play the
music library stored on the iPhone, or import audio files from the Files
app — all in one library, with one player.

- Multi-server library: Home and Search span every server; Albums, Artists,
  Songs and Playlists follow the default server
- Downloads with playlist sync, a stream cache and an Offline Mode
- Listening stats and mixes from on-device play history (nothing leaves
  the phone)
- Synced lyrics from LRCLIB, artwork fallbacks (Deezer, iTunes, Cover Art
  Archive), artist info from Wikipedia and Deezer
- Spotify **public playlist** import (track list read from the public embed
  page, matched against your servers)
- Song Radio, genres and decades browsing, sort options and format badges
- ListenBrainz scrobbling (optional, your own token)
- Home Screen and Lock Screen widgets, Siri shortcuts
- System / Light / Dark appearance, accent colours, larger text sizes and
  a haptics toggle

No accounts, no tracking. Passwords and tokens are stored only in the iOS
Keychain. The only data that leaves the phone goes to the servers and
services you configure.

## Build

- iOS 17+, Swift 5, no third-party dependencies
- Open `MatchaMusic.xcodeproj`, or use the GitHub Actions workflows:
  **Build IPA** (unsigned, for sideloading), **Simulator Test**, and
  **TestFlight** (signed upload)

## License

MIT — Copyright (c) 2026 c12n Apps
