//  Backend.swift — the MusicBackend protocol every source conforms to.
//  Design follows the Gemini backend pass (2026-10-29), hardened at integration:
//  stream/artwork URLs are synchronous best-effort (credentials are cached by
//  prepare()), and optional features have protocol-extension defaults so a
//  backend only implements what its server really supports.
import Foundation

protocol MusicBackend: AnyObject {
    var config: ServerConfig { get }
    var serverID: String { get }
    /// Authenticate / verify reachability. Also caches whatever streamURL and
    /// artworkURL need (tokens etc.).
    func prepare() async throws
    func artists() async throws -> [Artist]
    func artistAlbums(artistID: String) async throws -> [Album]
    func albums() async throws -> [Album]
    func albumSongs(albumID: String) async throws -> [Song]
    func songs() async throws -> [Song]
    func playlists() async throws -> [Playlist]
    func playlistSongs(playlistID: String) async throws -> [Song]
    func search(query: String) async throws -> SearchResults
    func streamURL(for song: Song) -> URL?
    func artworkURL(coverArtID: String) -> URL?
    func setFavourite(song: Song, favourite: Bool) async throws
    func createPlaylist(name: String, songIDs: [String]) async throws
    func addToPlaylist(playlistID: String, songIDs: [String]) async throws
    func scrobble(song: Song) async throws
    func genres() async throws -> [String]
    func albumsByGenre(_ genre: String) async throws -> [Album]
    func recentlyAdded(limit: Int) async throws -> [Album]
    func randomSongs(limit: Int) async throws -> [Song]
    func similarSongs(song: Song) async throws -> [Song]
    func starredSongs() async throws -> [Song]
}

extension MusicBackend {
    func artistAlbums(artistID: String) async throws -> [Album] {
        try await albums().filter { $0.artistID == artistID }
    }
    func addToPlaylist(playlistID: String, songIDs: [String]) async throws { throw BackendError.unsupported }
    func scrobble(song: Song) async throws {}
    func genres() async throws -> [String] { [] }
    func albumsByGenre(_ genre: String) async throws -> [Album] { [] }
    func recentlyAdded(limit: Int) async throws -> [Album] { Array(try await albums().prefix(limit)) }
    func randomSongs(limit: Int) async throws -> [Song] { Array(try await songs().shuffled().prefix(limit)) }
    func similarSongs(song: Song) async throws -> [Song] { [] }
    func starredSongs() async throws -> [Song] { try await songs().filter { $0.isFavourite } }
}

/// Factory: builds the right backend for a saved server config.
enum BackendFactory {
    static func make(_ config: ServerConfig) -> any MusicBackend {
        switch config.type {
        case .subsonic: return SubsonicAPI(config: config)
        case .jellyfin: return JellyfinAPI(config: config)
        case .plex: return PlexAPI(config: config)
        }
    }
}

/// Shared helpers for server backends.
enum BackendUtil {
    static func requireBaseURL(_ config: ServerConfig) throws -> URL {
        guard let url = config.baseURLValue, url.scheme != nil else { throw BackendError.invalidURL }
        return url
    }
    static func checkHTTP(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw BackendError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw BackendError.server("\(context) returned HTTP \(http.statusCode)") }
    }
    static var userAgent: String { "MatchaMusic/1.0 (iOS music player; com.c12n.matchamusic)" }
    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }
}
