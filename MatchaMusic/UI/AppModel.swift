//  AppModel.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Aggregates every backend (saved servers + the two on-device sources),
//  loads the library in parallel, caches it on disk so a relaunch shows
//  content instantly, and owns the actions the UI performs: favourites,
//  downloads, radio, playlists, server management and settings backup.
//
//  House rules kept here: secrets live ONLY in the Keychain; server
//  configs (no secrets) persist as JSON in UserDefaults; a server that
//  fails never empties the library — its error is surfaced instead.
import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let player = PlayerEngine.shared

    // MARK: Servers & backends
    private(set) var servers: [ServerConfig] = []
    private(set) var backends: [String: any MusicBackend] = [:]
    private(set) var localBackend: any MusicBackend
    private(set) var filesBackend: any MusicBackend
    private var preparedBackends: Set<String> = []

    // MARK: Library state (default server + on-device sources)
    private(set) var artists: [Artist] = []
    private(set) var albums: [Album] = []
    private(set) var songs: [Song] = []
    private(set) var playlists: [Playlist] = []
    private(set) var genres: [String] = []
    /// Favourites aggregated across ALL servers + local sources.
    private(set) var favourites: [Song] = []
    var isLoading: Bool = false
    var loadError: String?

    private static let serversKey = "matcha.servers"

    // MARK: - Init

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let local = LocalBackend()
        let files = LocalFilesBackend()
        self.localBackend = local
        self.filesBackend = files
        backends[LocalServerID.library] = local
        backends[LocalServerID.files] = files

        if let data = UserDefaults.standard.data(forKey: Self.serversKey),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
        for config in servers {
            backends[config.id] = BackendFactory.make(config)
        }
        loadCachedLibrary()

        // Player wiring: URL resolution + per-finished-song hooks.
        player.resolver = { [weak self] song in
            await self?.url(for: song)
        }
        player.onSongFinished = { [weak self] song, _ in
            guard let self else { return }
            Task { @MainActor in
                if self.settings.recordPlaysOnServer,
                   let backend = self.backend(for: song.serverID) {
                    try? await backend.scrobble(song: song)
                }
                // ListenBrainz gates itself on its enable toggle + token.
                await ListenBrainzScrobbler.shared.scrobble(song: song, listenedAt: Date())
                self.writeSnapshot()
            }
        }
    }

    // MARK: - Backend lookup

    func backend(for serverID: String) -> (any MusicBackend)? {
        backends[serverID]
    }

    var defaultServer: ServerConfig? {
        servers.first(where: { $0.isDefault }) ?? servers.first
    }

    /// Backends whose content fills the library tabs: the default server
    /// plus the two on-device sources.
    private var primaryBackends: [any MusicBackend] {
        var list: [any MusicBackend] = [localBackend, filesBackend]
        if let def = defaultServer, let backend = backends[def.id] {
            list.append(backend)
        }
        return list
    }

    private func ensurePrepared(_ backend: any MusicBackend) async throws {
        if preparedBackends.contains(backend.serverID) { return }
        try await backend.prepare()
        preparedBackends.insert(backend.serverID)
    }

    // MARK: - URL resolution (used by the player and downloads)

    /// Downloaded copy first, then the on-device file, then the owning
    /// backend's stream URL (after a one-time prepare()).
    func url(for song: Song) async -> URL? {
        if let local = DownloadManager.shared.localURL(for: song) { return local }
        guard let backend = backend(for: song.serverID) else { return song.localFileURL }
        if song.serverID == LocalServerID.library || song.serverID == LocalServerID.files {
            _ = try? await ensurePrepared(backend)
            return backend.streamURL(for: song) ?? song.localFileURL
        }
        _ = try? await ensurePrepared(backend)
        return backend.streamURL(for: song)
    }

    // MARK: - Offline-filtered, sorted display lists

    private func isOfflineAvailable(_ song: Song) -> Bool {
        song.serverID == LocalServerID.library
            || song.serverID == LocalServerID.files
            || DownloadManager.shared.isDownloaded(song)
    }

    var displaySongs: [Song] {
        let base = settings.offlineMode ? songs.filter(isOfflineAvailable) : songs
        switch settings.songSort {
        case .az: return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .newest: return base
        case .year: return base.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .mostPlayed:
            let counts = playCounts()
            return base.sorted { (counts[$0.uid] ?? 0) > (counts[$1.uid] ?? 0) }
        }
    }

    var displayAlbums: [Album] {
        var base = albums
        if settings.offlineMode {
            let downloaded = DownloadManager.shared.downloaded.values
            base = base.filter { album in
                album.serverID == LocalServerID.library || album.serverID == LocalServerID.files
                    || downloaded.contains { $0.albumID == album.id && $0.serverID == album.serverID }
            }
        }
        switch settings.albumSort {
        case .az: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest: return base
        case .year: return base.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .mostPlayed:
            let counts = playCounts()
            func totalPlays(_ album: Album) -> Int {
                songs.filter { $0.albumID == album.id && $0.serverID == album.serverID }
                    .reduce(0) { $0 + (counts[$1.uid] ?? 0) }
            }
            return base.sorted { totalPlays($0) > totalPlays($1) }
        }
    }

    var displayArtists: [Artist] {
        let base = settings.offlineMode
            ? artists.filter { $0.serverID == LocalServerID.library || $0.serverID == LocalServerID.files }
            : artists
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var displayPlaylists: [Playlist] {
        let base = settings.offlineMode
            ? playlists.filter {
                $0.serverID == LocalServerID.library || $0.serverID == LocalServerID.files
                    || DownloadManager.shared.isPlaylistSynced($0)
            }
            : playlists
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var cachedPlayCounts: [String: Int]?

    /// Play counts keyed by song uid, from the stats store.
    func playCounts() -> [String: Int] {
        if let cachedPlayCounts { return cachedPlayCounts }
        var map: [String: Int] = [:]
        for stat in PlayHistoryStore.shared.topSongs(limit: 100_000, since: .distantPast) {
            map[stat.uid] = stat.count
        }
        cachedPlayCounts = map
        return map
    }

    func invalidatePlayCounts() { cachedPlayCounts = nil }

    // MARK: - Loading

    private struct BackendLibrary {
        var artists: [Artist] = []
        var albums: [Album] = []
        var songs: [Song] = []
        var playlists: [Playlist] = []
        var genres: [String] = []
        var error: String?
    }

    func loadLibrary() async {
        if isLoading { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let primaries = primaryBackends
        var libraries: [BackendLibrary] = []
        await withTaskGroup(of: BackendLibrary.self) { group in
            for backend in primaries {
                group.addTask { await Self.fetchLibrary(from: backend) }
            }
            for await library in group { libraries.append(library) }
        }

        var mergedArtists: [Artist] = []
        var mergedAlbums: [Album] = []
        var mergedSongs: [Song] = []
        var mergedPlaylists: [Playlist] = []
        var mergedGenres = Set<String>()
        var firstError: String?
        for library in libraries {
            mergedArtists.append(contentsOf: library.artists)
            mergedAlbums.append(contentsOf: library.albums)
            mergedSongs.append(contentsOf: library.songs)
            mergedPlaylists.append(contentsOf: library.playlists)
            mergedGenres.formUnion(library.genres)
            if firstError == nil { firstError = library.error }
        }

        // Favourites aggregate across every backend, not just primaries.
        var allFavourites: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for backend in backends.values {
                group.addTask { (try? await backend.starredSongs()) ?? [] }
            }
            for await favs in group { allFavourites.append(contentsOf: favs) }
        }
        var seen = Set<String>()
        favourites = allFavourites
            .filter { seen.insert($0.uid).inserted }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        artists = mergedArtists
        albums = mergedAlbums
        songs = mergedSongs
        playlists = mergedPlaylists.map { playlist in
            var copy = playlist
            copy.isDownloadSynced = DownloadManager.shared.isPlaylistSynced(playlist)
            return copy
        }
        genres = mergedGenres.sorted()
        if let firstError {
            loadError = "Can't reach your server — \(firstError) Check the address in Settings, or remove and re-add the server."
        }
        invalidatePlayCounts()
        saveCachedLibrary()
        writeSnapshot()
        await refreshSyncedPlaylists()
    }

    private static func fetchLibrary(from backend: any MusicBackend) async -> BackendLibrary {
        var library = BackendLibrary()
        do {
            try await backend.prepare()
        } catch {
            library.error = error.localizedDescription
            return library
        }
        func collect<T>(_ work: () async throws -> [T], into assign: ([T]) -> Void) async {
            do { assign(try await work()) }
            catch { if library.error == nil { library.error = error.localizedDescription } }
        }
        await collect({ try await backend.artists() }) { library.artists = $0 }
        await collect({ try await backend.albums() }) { library.albums = $0 }
        await collect({ try await backend.songs() }) { library.songs = $0 }
        await collect({ try await backend.playlists() }) { library.playlists = $0 }
        await collect({ try await backend.genres() }) { library.genres = $0 }
        return library
    }

    // MARK: Disk cache

    private struct LibraryCache: Codable {
        var artists: [Artist]
        var albums: [Album]
        var songs: [Song]
        var playlists: [Playlist]
        var genres: [String]
        var favourites: [Song]
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryCache.json")
    }

    private func loadCachedLibrary() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(LibraryCache.self, from: data) else { return }
        artists = cache.artists
        albums = cache.albums
        songs = cache.songs
        playlists = cache.playlists
        genres = cache.genres
        favourites = cache.favourites
    }

    private func saveCachedLibrary() {
        let cache = LibraryCache(artists: artists, albums: albums, songs: songs,
                                 playlists: playlists, genres: genres, favourites: favourites)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Per-item fetches

    func albumSongs(_ album: Album) async -> [Song] {
        guard let backend = backend(for: album.serverID) else { return [] }
        _ = try? await ensurePrepared(backend)
        return (try? await backend.albumSongs(albumID: album.id)) ?? []
    }

    func artistAlbums(_ artist: Artist) async -> [Album] {
        guard let backend = backend(for: artist.serverID) else { return [] }
        _ = try? await ensurePrepared(backend)
        return (try? await backend.artistAlbums(artistID: artist.id)) ?? []
    }

    func playlistSongs(_ playlist: Playlist) async -> [Song] {
        guard let backend = backend(for: playlist.serverID) else { return [] }
        _ = try? await ensurePrepared(backend)
        return (try? await backend.playlistSongs(playlistID: playlist.id)) ?? []
    }

    func recentlyAdded() async -> [Album] {
        var result: [Album] = []
        await withTaskGroup(of: [Album].self) { group in
            for backend in primaryBackends {
                group.addTask { (try? await backend.recentlyAdded(limit: 20)) ?? [] }
            }
            for await batch in group { result.append(contentsOf: batch) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.uid).inserted }
    }

    func albumsByGenre(_ genre: String) async -> [Album] {
        var result: [Album] = []
        await withTaskGroup(of: [Album].self) { group in
            for backend in backends.values {
                group.addTask { (try? await backend.albumsByGenre(genre)) ?? [] }
            }
            for await batch in group { result.append(contentsOf: batch) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.uid).inserted }
    }

    // MARK: - Search

    func search(query: String) async -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }
        var combined = SearchResults()
        await withTaskGroup(of: SearchResults.self) { group in
            for backend in backends.values {
                group.addTask { (try? await backend.search(query: trimmed)) ?? SearchResults() }
            }
            for await result in group {
                combined.artists.append(contentsOf: result.artists)
                combined.albums.append(contentsOf: result.albums)
                combined.songs.append(contentsOf: result.songs)
            }
        }
        var seenSongs = Set<String>()
        combined.songs = combined.songs.filter { seenSongs.insert($0.uid).inserted }
        var seenAlbums = Set<String>()
        combined.albums = combined.albums.filter { seenAlbums.insert($0.uid).inserted }
        var seenArtists = Set<String>()
        combined.artists = combined.artists.filter { seenArtists.insert($0.uid).inserted }
        return combined
    }

    // MARK: - Favourites

    func toggleFavourite(song input: Song) async {
        guard let backend = backend(for: input.serverID) else { return }
        let newValue = !input.isFavourite
        applyFavourite(newValue, toSongUID: input.uid)
        do {
            _ = try? await ensurePrepared(backend)
            try await backend.setFavourite(song: input, favourite: newValue)
        } catch {
            applyFavourite(!newValue, toSongUID: input.uid)
            loadError = error.localizedDescription
            return
        }
        if newValue {
            favourites.append(contentsOf: songs.filter { $0.uid == input.uid && $0.isFavourite })
            var seen = Set<String>()
            favourites = favourites.filter { seen.insert($0.uid).inserted }
        } else {
            favourites.removeAll { $0.uid == input.uid }
        }
        writeSnapshot()
        if newValue, settings.autoDownloadFavourites,
           input.serverID != LocalServerID.library, input.serverID != LocalServerID.files {
            let updated = songs.first { $0.uid == input.uid } ?? input
            if let url = await url(for: updated) {
                await DownloadManager.shared.download(song: updated, url: url)
            }
        }
    }

    private func applyFavourite(_ value: Bool, toSongUID uid: String) {
        for index in songs.indices where songs[index].uid == uid { songs[index].isFavourite = value }
        for index in favourites.indices where favourites[index].uid == uid { favourites[index].isFavourite = value }
    }

    // MARK: - Downloads

    func downloadAlbumSongs(_ albumSongs: [Song]) async {
        for song in albumSongs where !DownloadManager.shared.isDownloaded(song) {
            if let url = await url(for: song) {
                await DownloadManager.shared.download(song: song, url: url)
            }
        }
    }

    func refreshSyncedPlaylists() async {
        for playlist in playlists where DownloadManager.shared.isPlaylistSynced(playlist) {
            let tracks = await playlistSongs(playlist)
            for song in tracks where !DownloadManager.shared.isDownloaded(song) {
                if let url = await url(for: song) {
                    await DownloadManager.shared.download(song: song, url: url)
                }
            }
        }
    }

    // MARK: - Playlists & radio

    /// Creates a playlist on one server. `songIDs` are backend-native IDs;
    /// only songs that live on that server are included.
    func createPlaylist(name: String, songIDs: [String], onServer serverID: String) async throws {
        guard let backend = backend(for: serverID) else { throw BackendError.missingData }
        try await ensurePrepared(backend)
        try await backend.createPlaylist(name: name, songIDs: songIDs)
    }

    func createPlaylist(name: String, fromQueueSongs queueSongs: [Song], onServer serverID: String) async throws {
        let ids = queueSongs.filter { $0.serverID == serverID }.map { $0.id }
        try await createPlaylist(name: name, songIDs: ids, onServer: serverID)
    }

    func addToPlaylist(_ playlist: Playlist, songs newSongs: [Song]) async {
        guard let backend = backend(for: playlist.serverID) else { return }
        let ids = newSongs.filter { $0.serverID == playlist.serverID }.map { $0.id }
        guard !ids.isEmpty else {
            loadError = "Those songs live on a different server than the playlist."
            return
        }
        do {
            try await ensurePrepared(backend)
            try await backend.addToPlaylist(playlistID: playlist.id, songIDs: ids)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func startRadio(song: Song) async {
        guard let backend = backend(for: song.serverID) else { return }
        _ = try? await ensurePrepared(backend)
        let similar = (try? await backend.similarSongs(song: song)) ?? []
        guard !similar.isEmpty else {
            loadError = "This server couldn't suggest similar songs."
            return
        }
        player.play(songs: [song] + similar.filter { $0.uid != song.uid }, startIndex: 0, model: self)
        writeSnapshot()
    }

    // MARK: - Lookup helpers

    func song(byUID uid: String) -> Song? {
        songs.first { $0.uid == uid }
            ?? favourites.first { $0.uid == uid }
            ?? DownloadManager.shared.downloaded.values.first { $0.uid == uid }
    }

    /// Recently played songs, newest first, rebuilt from the stats store
    /// and matched back to library songs where possible.
    func recentSongs(limit: Int = 10) -> [Song] {
        let stats = PlayHistoryStore.shared.topSongs(limit: 500, since: .distantPast)
            .sorted { $0.lastPlayed > $1.lastPlayed }
        var result: [Song] = []
        for stat in stats {
            if let song = song(byUID: stat.uid) {
                result.append(song)
            } else {
                let rawID = stat.uid.hasPrefix(stat.serverID + "|")
                    ? String(stat.uid.dropFirst(stat.serverID.count + 1)) : stat.uid
                result.append(Song(id: rawID, serverID: stat.serverID, title: stat.title,
                                   artist: stat.artist, album: stat.album, albumID: "",
                                   artistID: "", coverArtID: stat.coverArtID, duration: 0,
                                   isFavourite: false, localFileURL: nil, suffix: nil,
                                   bitRate: nil, genre: nil, year: nil))
            }
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - Local files

    func reloadLocalFiles() async {
        let fresh = LocalFilesBackend()
        filesBackend = fresh
        backends[LocalServerID.files] = fresh
        preparedBackends.remove(LocalServerID.files)
        await loadLibrary()
    }

    // MARK: - Server management

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }

    /// Saves the secret to the Keychain FIRST (backends read their secret
    /// from the Keychain by config id when prepare() runs), then registers
    /// the server and reloads the library.
    func addServer(config: ServerConfig, secret: String) {
        KeychainStore.set(secret, account: KeychainStore.serverSecretAccount(config.id))
        var config = config
        if config.isDefault {
            for index in servers.indices { servers[index].isDefault = false }
        } else if servers.isEmpty {
            config.isDefault = true
        }
        servers.append(config)
        backends[config.id] = BackendFactory.make(config)
        preparedBackends.remove(config.id)
        persistServers()
        Task { await loadLibrary() }
    }

    /// Tests a not-yet-saved server. The secret is written to the Keychain
    /// under the config's id first (that is the only channel backends
    /// have); if the test fails the secret is removed again, and if the
    /// add-server screen is cancelled afterwards the caller is expected
    /// to remove it too. On success the secret stays, ready for
    /// addServer(config:secret:).
    func testServer(config: ServerConfig, secret: String) async throws {
        KeychainStore.set(secret, account: KeychainStore.serverSecretAccount(config.id))
        let backend = BackendFactory.make(config)
        do {
            try await backend.prepare()
        } catch {
            KeychainStore.remove(KeychainStore.serverSecretAccount(config.id))
            throw error
        }
    }

    func removeServer(_ config: ServerConfig) {
        KeychainStore.remove(KeychainStore.serverSecretAccount(config.id))
        servers.removeAll { $0.id == config.id }
        backends.removeValue(forKey: config.id)
        preparedBackends.remove(config.id)
        if !servers.isEmpty, !servers.contains(where: { $0.isDefault }) {
            servers[0].isDefault = true
        }
        artists.removeAll { $0.serverID == config.id }
        albums.removeAll { $0.serverID == config.id }
        songs.removeAll { $0.serverID == config.id }
        playlists.removeAll { $0.serverID == config.id }
        favourites.removeAll { $0.serverID == config.id }
        persistServers()
        saveCachedLibrary()
    }

    func setDefaultServer(_ config: ServerConfig) {
        for index in servers.indices {
            servers[index].isDefault = servers[index].id == config.id
        }
        persistServers()
        Task { await loadLibrary() }
    }

    // MARK: - Siri / Shortcuts pending commands

    /// Shortcuts store a command in the App Group defaults; the app
    /// consumes it when it comes to the foreground.
    func consumePendingShortcutCommand() {
        guard let defaults = UserDefaults(suiteName: SharedSnapshot.suiteName),
              let command = defaults.string(forKey: "pendingCommand"), !command.isEmpty else { return }
        defaults.removeObject(forKey: "pendingCommand")
        switch command {
        case "favourites":
            if !favourites.isEmpty {
                player.play(songs: favourites, startIndex: 0, model: self)
            } else {
                Task { await loadLibrary(); if !favourites.isEmpty { player.play(songs: favourites, startIndex: 0, model: self) } }
            }
        case "shuffle":
            let all = displaySongs
            if !all.isEmpty {
                player.play(songs: all.shuffled(), startIndex: 0, model: self)
            }
        case "recent":
            let recent = recentSongs(limit: 25)
            if !recent.isEmpty {
                player.play(songs: recent, startIndex: 0, model: self)
            }
        default:
            break
        }
        writeSnapshot()
    }

    // MARK: - Widget snapshot

    func writeSnapshot() {
        let snapshot = SharedSnapshot(
            currentTitle: player.currentSong?.title ?? "",
            currentArtist: player.currentSong?.artist ?? "",
            isPlaying: player.isPlaying,
            favourites: favourites.prefix(5).map { $0.title },
            recent: recentSongs(limit: 5).map { $0.title }
        )
        SharedSnapshot.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Settings backup (secrets are NEVER included)

    private struct SettingsBackup: Codable {
        var servers: [ServerConfig]
        var appearance: String
        var accent: String
        var streamingQuality: String
        var exportedAt: Date
    }

    func exportSettings() -> URL {
        let backup = SettingsBackup(
            servers: servers,
            appearance: settings.appearance.rawValue,
            accent: settings.accent.rawValue,
            streamingQuality: settings.streamingQuality.rawValue,
            exportedAt: Date()
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MatchaMusic-Settings.json")
        if let data = try? JSONEncoder().encode(backup) {
            try? data.write(to: url, options: .atomic)
        }
        return url
    }

    /// Imports servers + preferences from a backup. Passwords and tokens
    /// are not in the file, so imported servers will fail prepare() with
    /// "unauthorized" until their password is entered again by editing —
    /// the load error surfaces that plainly.
    func importSettings(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: data)
        for config in backup.servers where !servers.contains(where: { $0.id == config.id }) {
            var config = config
            if !servers.isEmpty { config.isDefault = false }
            servers.append(config)
            backends[config.id] = BackendFactory.make(config)
        }
        if let appearance = AppearanceMode(rawValue: backup.appearance) { settings.appearance = appearance }
        if let accent = AccentChoice(rawValue: backup.accent) { settings.accent = accent }
        if let quality = StreamingQuality(rawValue: backup.streamingQuality) { settings.streamingQuality = quality }
        persistServers()
        Task { await loadLibrary() }
    }
}
