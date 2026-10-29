# Gemini backend pass — returned 2026-10-29 16:06 CST (ran 15:58–16:06)
Model: Gemini 3.1 Pro, thinking High ("Extra thorough") — verified in picker. Chat: https://gemini.google.com/app/6423c884da2cdf93 (full code lives in that chat; re-open it to retrieve verbatim if needed during integration).
Delivered: Backend.swift (revised: Song.suffix/bitRate, ServerType.local_files, extended protocol genres/albumsByGenre/recentlyAdded/randomSongs/similarSongs), SubsonicAPI, JellyfinAPI, PlexAPI, LocalBackend, Artwork, Lyrics, Downloads, StreamCache, SpotifyImport, ListenBrainz, LocalFilesBackend.
KNOWN GAPS to fix at integration (from the report):
- Artwork MusicBrainz resolver returns nil (implement MB release-group -> CoverArtArchive).
- LocalBackend search returns empty (implement filter over songs/albums/artists).
- Plex: setFavourite/createPlaylist are empty stubs (implement via /library/metadata/{id} rate + /playlists POST); PIN auth NOT implemented (implement pins create/poll + app.plex.tv/auth URL + resources picking; token currently read from Keychain service matcha_plex).
- Downloads: no progress callbacks, no album/playlist download, no playlist-sync re-check, no remove-single, no total size (implement).
- Lyrics: no /api/search fallback, no current-line lookup (implement both).
- LocalFilesBackend: genres/albumsByGenre/search/playlists empty; recentlyAdded not sorted by creation date (implement search at least; sort recentlyAdded).
- Subsonic fetch uses a fragile envelope re-encode (JSONWrapper encode is empty) — replace with direct DTOs decoding the whole subsonic-response envelope per endpoint, or a [String: Any] + re-serialize that actually works. VERIFY carefully.
- Jellyfin genres uses IncludeItemTypes=Genre on /Items — real route is GET /Genres; fix. Fields param needed for MediaSources. streamURL needs api_key + token auth state (authenticate before building URL).
- Plex streamURL builds path from 127.0.0.1:32400 — should use the track's Media Part key from metadata; store part key on Song or fetch metadata at play time.
- Gemini KeychainHelper is read-only and services (matcha_subsonic etc.) don't match Claude's Keychain design — unify on ONE Keychain wrapper + one service naming scheme at integration.
- Actors conforming to MusicBackend with sync streamURL/artworkURL — check Swift concurrency: protocol methods are async in effect via actor isolation except nonisolated ones; mark streamURL/artworkURL nonisolated or make protocol funcs async. Resolve at integration.
