//  LocalFilesBackend.swift — audio files imported into the app sandbox.
//  Copyright (c) 2026 c12n Apps
//
//  Scans Application Support/LocalFiles on every call (the folder is small
//  and user-managed, so there is no cache to invalidate). Metadata comes
//  from AVAsset's common metadata; song ids are "file:" + the path relative
//  to the LocalFiles folder, so they stay stable across launches. Favourites
//  are a local id set, exactly like the Music-library backend.
import Foundation
import AVFoundation

final class LocalFilesBackend: MusicBackend {
    let config: ServerConfig
    var serverID: String { config.id }

    private static let defaultConfig = ServerConfig(
        id: LocalServerID.files, name: "Local Files", type: .subsonic,
        baseURL: "file://", username: "", isDefault: false)
    private static let favouritesKey = "matcha.localfiles.favourites"
    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "aac", "aiff", "aif", "caf", "alac"
    ]

    init() {
        self.config = Self.defaultConfig
    }

    init(config: ServerConfig) {
        self.config = config
    }

    /// The folder the importer copies files into (and the scanner reads).
    static func directory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("LocalFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Favourites (local set)

    private var favouriteIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.favouritesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.favouritesKey) }
    }

    // MARK: - Scanning

    private struct Entry {
        var song: Song
        var modified: Date
    }

    private func scanEntries() -> [Entry] {
        let dir = Self.directory()
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            if url.hasDirectoryPath { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            entries.append(Entry(song: makeSong(fileURL: url, in: dir, ext: ext), modified: modified))
        }
        return entries
    }

    private func scan() -> [Song] {
        scanEntries().map { $0.song }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func makeSong(fileURL: URL, in dir: URL, ext: String) -> Song {
        let relativePath = fileURL.path.hasPrefix(dir.path)
            ? String(fileURL.path.dropFirst(dir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : fileURL.lastPathComponent
        let id = "file:" + relativePath

        let asset = AVURLAsset(url: fileURL)
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: Int?
        for item in asset.commonMetadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: title = item.stringValue
            case .commonKeyArtist: artist = item.stringValue
            case .commonKeyAlbumName: album = item.stringValue
            case .commonKeyType: genre = item.stringValue
            case .commonKeyCreationDate:
                if let value = item.stringValue, value.count >= 4 {
                    year = Int(value.prefix(4))
                }
            default: break
            }
        }
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let duration = durationSeconds.isFinite ? Int(durationSeconds) : 0

        var bitRate: Int?
        if duration > 0,
           let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
           size > 0 {
            bitRate = (size * 8) / (duration * 1000)
        }

        let resolvedArtist = artist ?? "Unknown Artist"
        let resolvedAlbum = album ?? "Unknown Album"
        return Song(id: id, serverID: serverID,
                    title: title ?? fileURL.deletingPathExtension().lastPathComponent,
                    artist: resolvedArtist,
                    album: resolvedAlbum,
                    albumID: "album:\(resolvedArtist)|\(resolvedAlbum)",
                    artistID: "artist:\(resolvedArtist)",
                    coverArtID: id,
                    duration: duration,
                    isFavourite: favouriteIDs.contains(id),
                    localFileURL: fileURL,
                    suffix: ext, bitRate: bitRate,
                    genre: genre, year: year)
    }

    // MARK: - Grouping

    private func albums(from songs: [Song]) -> [Album] {
        Dictionary(grouping: songs, by: { $0.albumID })
            .values
            .compactMap { group -> Album? in
                guard let first = group.first else { return nil }
                return Album(id: first.albumID, serverID: serverID,
                             name: first.album,
                             artist: first.artist,
                             artistID: first.artistID,
                             coverArtID: first.id,
                             songCount: group.count,
                             duration: group.reduce(0) { $0 + $1.duration },
                             year: group.compactMap { $0.year }.first,
                             genre: group.compactMap { $0.genre }.first)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func artists(from songs: [Song]) -> [Artist] {
        Dictionary(grouping: songs, by: { $0.artistID })
            .values
            .compactMap { group -> Artist? in
                guard let first = group.first else { return nil }
                return Artist(id: first.artistID, serverID: serverID,
                              name: first.artist,
                              albumCount: Set(group.map { $0.albumID }).count,
                              coverArtID: first.id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - MusicBackend

    func prepare() async throws {
        _ = Self.directory()
    }

    func artists() async throws -> [Artist] {
        artists(from: scan())
    }

    func artistAlbums(artistID: String) async throws -> [Album] {
        albums(from: scan().filter { $0.artistID == artistID })
    }

    func albums() async throws -> [Album] {
        albums(from: scan())
    }

    func albumSongs(albumID: String) async throws -> [Song] {
        scan().filter { $0.albumID == albumID }
    }

    func songs() async throws -> [Song] {
        scan()
    }

    func playlists() async throws -> [Playlist] {
        // Imported files have no playlists of their own.
        []
    }

    func playlistSongs(playlistID: String) async throws -> [Song] {
        []
    }

    func search(query: String) async throws -> SearchResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SearchResults() }
        let all = scan()
        func matches(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(needle) }
        return SearchResults(
            artists: artists(from: all).filter { matches($0.name) },
            albums: albums(from: all).filter { matches($0.name) || matches($0.artist) },
            songs: all.filter { matches($0.title) || matches($0.artist) || matches($0.album) })
    }

    func streamURL(for song: Song) -> URL? {
        song.localFileURL
    }

    func artworkURL(coverArtID: String) -> URL? {
        // Artwork is embedded in the audio files; the UI extracts it from
        // the file URL, so there is no remote artwork endpoint here.
        nil
    }

    func setFavourite(song: Song, favourite: Bool) async throws {
        var ids = favouriteIDs
        if favourite { ids.insert(song.id) } else { ids.remove(song.id) }
        favouriteIDs = ids
    }

    func createPlaylist(name: String, songIDs: [String]) async throws {
        throw BackendError.unsupported
    }

    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        throw BackendError.unsupported
    }

    func genres() async throws -> [String] {
        Array(Set(scan().compactMap { $0.genre }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func albumsByGenre(_ genre: String) async throws -> [Album] {
        albums(from: scan().filter { $0.genre == genre })
    }

    func recentlyAdded(limit: Int) async throws -> [Album] {
        let entries = scanEntries().sorted { $0.modified > $1.modified }
        var orderedAlbumIDs: [String] = []
        var seen: Set<String> = []
        for entry in entries where seen.insert(entry.song.albumID).inserted {
            orderedAlbumIDs.append(entry.song.albumID)
        }
        let byID = Dictionary(uniqueKeysWithValues: albums(from: entries.map { $0.song }).map { ($0.id, $0) })
        return orderedAlbumIDs.prefix(max(1, limit)).compactMap { byID[$0] }
    }

    func randomSongs(limit: Int) async throws -> [Song] {
        Array(scan().shuffled().prefix(max(1, limit)))
    }

    func similarSongs(song: Song) async throws -> [Song] {
        Array(scan()
            .filter { $0.artistID == song.artistID && $0.id != song.id }
            .shuffled()
            .prefix(50))
    }

    func starredSongs() async throws -> [Song] {
        scan().filter { $0.isFavourite }
    }
}
