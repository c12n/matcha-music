//  LocalBackend.swift — the on-iPhone Music library (MediaPlayer).
//  Copyright (c) 2026 c12n Apps
//
//  Wraps MPMediaQuery. MediaPlayer has no writable favourite flag, so
//  favourites are a local set of persistentIDs in UserDefaults. Playlists
//  are real library playlists: creating one uses MPMediaLibrary's
//  getPlaylist API, and adding songs looks the items up by persistentID.
import Foundation
import MediaPlayer

final class LocalBackend: MusicBackend {
    let config: ServerConfig
    var serverID: String { config.id }

    private static let defaultConfig = ServerConfig(
        id: LocalServerID.library, name: "On This iPhone", type: .subsonic,
        baseURL: "ipod-library://", username: "", isDefault: false)
    private static let favouritesKey = "matcha.local.favourites"

    init() {
        self.config = Self.defaultConfig
    }

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Favourites (local set)

    private var favouriteIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.favouritesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.favouritesKey) }
    }

    // MARK: - Authorisation

    private func ensureAuthorized() async throws {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await MPMediaLibrary.requestAuthorization()
            guard status == .authorized else { throw BackendError.unauthorized }
        default:
            throw BackendError.unauthorized
        }
    }

    // MARK: - Mapping

    private func mapSong(_ item: MPMediaItem) -> Song {
        let id = String(item.persistentID)
        return Song(id: id, serverID: serverID,
                    title: item.title ?? "Unknown Title",
                    artist: item.artist ?? "",
                    album: item.albumTitle ?? "",
                    albumID: String(item.albumPersistentID),
                    artistID: String(item.artistPersistentID),
                    coverArtID: id,
                    duration: Int(item.playbackDuration),
                    isFavourite: favouriteIDs.contains(id),
                    localFileURL: item.assetURL,
                    suffix: item.assetURL?.pathExtension.lowercased(),
                    bitRate: nil,
                    genre: item.genre,
                    year: item.releaseDate.map { Calendar.current.component(.year, from: $0) })
    }

    private func mapAlbum(_ collection: MPMediaItemCollection) -> Album? {
        guard let rep = collection.representativeItem else { return nil }
        return Album(id: String(rep.albumPersistentID), serverID: serverID,
                     name: rep.albumTitle ?? "Unknown Album",
                     artist: rep.albumArtist ?? rep.artist ?? "",
                     artistID: String(rep.artistPersistentID),
                     coverArtID: String(rep.albumPersistentID),
                     songCount: collection.count,
                     duration: Int(collection.items.reduce(0) { $0 + $1.playbackDuration }),
                     year: rep.releaseDate.map { Calendar.current.component(.year, from: $0) },
                     genre: rep.genre)
    }

    private func mapArtist(_ collection: MPMediaItemCollection) -> Artist? {
        guard let rep = collection.representativeItem else { return nil }
        return Artist(id: String(rep.artistPersistentID), serverID: serverID,
                      name: rep.artist ?? "Unknown Artist",
                      albumCount: Set(collection.items.map { $0.albumPersistentID }).count,
                      coverArtID: String(rep.artistPersistentID))
    }

    private func mapPlaylist(_ playlist: MPMediaPlaylist) -> Playlist {
        Playlist(id: String(playlist.persistentID), serverID: serverID,
                 name: playlist.name ?? "Playlist",
                 songCount: playlist.count,
                 duration: Int(playlist.items.reduce(0) { $0 + $1.playbackDuration }),
                 coverArtID: String(playlist.persistentID),
                 isDownloadSynced: false)
    }

    // MARK: - MusicBackend

    func prepare() async throws {
        try await ensureAuthorized()
    }

    func artists() async throws -> [Artist] {
        try await ensureAuthorized()
        return (MPMediaQuery.artists().collections ?? []).compactMap(mapArtist)
    }

    func artistAlbums(artistID: String) async throws -> [Album] {
        try await ensureAuthorized()
        return (MPMediaQuery.albums().collections ?? [])
            .filter { collection in
                guard let rep = collection.representativeItem else { return false }
                return String(rep.artistPersistentID) == artistID
            }
            .compactMap(mapAlbum)
    }

    func albums() async throws -> [Album] {
        try await ensureAuthorized()
        return (MPMediaQuery.albums().collections ?? []).compactMap(mapAlbum)
    }

    func albumSongs(albumID: String) async throws -> [Song] {
        try await ensureAuthorized()
        guard let collection = (MPMediaQuery.albums().collections ?? []).first(where: {
            guard let rep = $0.representativeItem else { return false }
            return String(rep.albumPersistentID) == albumID
        }) else { return [] }
        return collection.items.map(mapSong)
    }

    func songs() async throws -> [Song] {
        try await ensureAuthorized()
        return (MPMediaQuery.songs().items ?? []).map(mapSong)
    }

    func playlists() async throws -> [Playlist] {
        try await ensureAuthorized()
        return (MPMediaQuery.playlists().collections ?? [])
            .compactMap { $0 as? MPMediaPlaylist }
            .map(mapPlaylist)
    }

    func playlistSongs(playlistID: String) async throws -> [Song] {
        try await ensureAuthorized()
        guard let playlist = (MPMediaQuery.playlists().collections ?? [])
            .compactMap({ $0 as? MPMediaPlaylist })
            .first(where: { String($0.persistentID) == playlistID }) else { return [] }
        return playlist.items.map(mapSong)
    }

    func search(query: String) async throws -> SearchResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SearchResults() }
        let allSongs = try await songs()
        let allAlbums = try await albums()
        let allArtists = try await artists()
        func matches(_ text: String) -> Bool {
            text.localizedCaseInsensitiveContains(needle)
        }
        return SearchResults(
            artists: allArtists.filter { matches($0.name) },
            albums: allAlbums.filter { matches($0.name) || matches($0.artist) },
            songs: allSongs.filter { matches($0.title) || matches($0.artist) || matches($0.album) })
    }

    func streamURL(for song: Song) -> URL? {
        song.localFileURL
    }

    func artworkURL(coverArtID: String) -> URL? {
        // Local artwork comes from MPMediaItemArtwork in the UI layer.
        nil
    }

    func setFavourite(song: Song, favourite: Bool) async throws {
        var ids = favouriteIDs
        if favourite { ids.insert(song.id) } else { ids.remove(song.id) }
        favouriteIDs = ids
    }

    func createPlaylist(name: String, songIDs: [String]) async throws {
        try await ensureAuthorized()
        let metadata = MPMediaPlaylistCreationMetadata()
        metadata.name = name
        let playlist: MPMediaPlaylist = try await withCheckedThrowingContinuation { continuation in
            MPMediaLibrary.default().getPlaylist(
                with: UUID(),
                creationMetadata: metadata
            ) { playlist, error in
                if let playlist {
                    continuation.resume(returning: playlist)
                } else {
                    continuation.resume(throwing: error ?? BackendError.missingData)
                }
            }
        }
        try await addItems(withIDs: songIDs, to: playlist)
    }

    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        try await ensureAuthorized()
        guard let playlist = (MPMediaQuery.playlists().collections ?? [])
            .compactMap({ $0 as? MPMediaPlaylist })
            .first(where: { String($0.persistentID) == playlistID }) else {
            throw BackendError.missingData
        }
        try await addItems(withIDs: songIDs, to: playlist)
    }

    private func addItems(withIDs songIDs: [String], to playlist: MPMediaPlaylist) async throws {
        guard !songIDs.isEmpty else { return }
        let wanted = Set(songIDs)
        let items = (MPMediaQuery.songs().items ?? []).filter { wanted.contains(String($0.persistentID)) }
        guard !items.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playlist.add(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func genres() async throws -> [String] {
        try await ensureAuthorized()
        let names = (MPMediaQuery.genres().collections ?? [])
            .compactMap { $0.representativeItem?.genre }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func albumsByGenre(_ genre: String) async throws -> [Album] {
        try await ensureAuthorized()
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: genre, forProperty: MPMediaItemPropertyGenre, comparisonType: .equalTo))
        return (query.collections ?? []).compactMap(mapAlbum)
    }

    func recentlyAdded(limit: Int) async throws -> [Album] {
        try await ensureAuthorized()
        let sorted = (MPMediaQuery.albums().collections ?? []).sorted { a, b in
            let dateA = a.representativeItem?.dateAdded ?? .distantPast
            let dateB = b.representativeItem?.dateAdded ?? .distantPast
            return dateA > dateB
        }
        return sorted.prefix(max(1, limit)).compactMap(mapAlbum)
    }

    func randomSongs(limit: Int) async throws -> [Song] {
        try await songs().shuffled().prefix(max(1, limit)).map { $0 }
    }

    func similarSongs(song: Song) async throws -> [Song] {
        let all = try await songs()
        var collected: [Song] = []
        var seen: Set<String> = [song.id]
        // Same artist first, then same genre — a simple, honest "radio".
        for candidate in all where candidate.artistID == song.artistID || candidate.artist == song.artist {
            if seen.insert(candidate.id).inserted { collected.append(candidate) }
        }
        if let genre = song.genre, !genre.isEmpty {
            for candidate in all where candidate.genre == genre {
                if seen.insert(candidate.id).inserted { collected.append(candidate) }
            }
        }
        return Array(collected.shuffled().prefix(50))
    }

    func starredSongs() async throws -> [Song] {
        try await songs().filter { $0.isFavourite }
    }
}
