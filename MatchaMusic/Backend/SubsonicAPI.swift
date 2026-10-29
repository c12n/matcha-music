//  SubsonicAPI.swift — Navidrome / Subsonic backend.
//  Copyright (c) 2026 c12n Apps
//
//  Talks to the Subsonic REST API (v=1.16.1) in JSON mode. Auth is the
//  token+salt scheme: a random salt is persisted per server and the token is
//  MD5(password + salt), so the password itself never travels. The full
//  "subsonic-response" envelope is decoded with per-endpoint DTOs rooted at
//  that key; a "failed" envelope surfaces the server's own error message.
import Foundation
import CryptoKit

final class SubsonicAPI: MusicBackend {
    let config: ServerConfig
    var serverID: String { config.id }

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Auth / URL building

    private var password: String? {
        KeychainStore.get(KeychainStore.serverSecretAccount(config.id))
    }

    /// Random salt, generated once per server and persisted (it is not a
    /// secret — the password is).
    private var salt: String {
        let key = "matcha.subsonic.salt.\(config.id)"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max)) }.joined()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func authItems() throws -> [URLQueryItem] {
        guard let password else { throw BackendError.unauthorized }
        let s = salt
        return [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: md5Hex(password + s)),
            URLQueryItem(name: "s", value: s),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "MatchaMusic"),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    private func syncAuthItems() -> [URLQueryItem]? {
        guard let password else { return nil }
        let s = salt
        return [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: md5Hex(password + s)),
            URLQueryItem(name: "s", value: s),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "MatchaMusic"),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    private func makeURL(endpoint: String, extra: [URLQueryItem]) throws -> URL {
        let base = try BackendUtil.requireBaseURL(config)
        var components = URLComponents(
            url: base.appendingPathComponent("rest").appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false)
        components?.queryItems = try authItems() + extra
        guard let url = components?.url else { throw BackendError.invalidURL }
        return url
    }

    /// Streaming-quality cap in kbps, read straight from UserDefaults
    /// ("original" / unset means no cap).
    private var maxBitRateKbps: Int? {
        switch UserDefaults.standard.string(forKey: "matcha_streaming_quality") ?? "original" {
        case "high": return 320
        case "medium": return 192
        case "low": return 128
        default: return nil
        }
    }

    // MARK: - Envelope decoding

    private struct ErrorDTO: Decodable {
        var code: Int?
        var message: String?
    }

    private struct Root<Payload: Decodable>: Decodable {
        var body: Body<Payload>
        enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
    }

    private struct Body<Payload: Decodable>: Decodable {
        var payload: Payload
        private enum Keys: String, CodingKey { case status, error }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let status = try container.decodeIfPresent(String.self, forKey: .status)
            if status == "failed" {
                let serverError = try container.decodeIfPresent(ErrorDTO.self, forKey: .error)
                throw BackendError.server(serverError?.message ?? "The server reported an error.")
            }
            payload = try Payload(from: decoder)
        }
    }

    private struct EmptyPayload: Decodable {}

    private func fetch<Payload: Decodable>(_ endpoint: String, extra: [URLQueryItem] = []) async throws -> Payload {
        let url = try makeURL(endpoint: endpoint, extra: extra)
        do {
            let (data, response) = try await URLSession.shared.data(for: BackendUtil.request(url))
            try BackendUtil.checkHTTP(response, context: "Subsonic")
            return try JSONDecoder().decode(Root<Payload>.self, from: data).body.payload
        } catch let error as BackendError {
            throw error
        } catch let error as DecodingError {
            throw BackendError.server("Couldn't read the server's response. \(error.localizedDescription)")
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }

    private func fetchVoid(_ endpoint: String, extra: [URLQueryItem] = []) async throws {
        let _: EmptyPayload = try await fetch(endpoint, extra: extra)
    }

    // MARK: - DTOs

    private struct SongDTO: Decodable {
        var id: String
        var title: String?
        var album: String?
        var artist: String?
        var albumId: String?
        var artistId: String?
        var coverArt: String?
        var duration: Int?
        var bitRate: Int?
        var suffix: String?
        var genre: String?
        var year: Int?
        var starred: String?
    }

    private struct AlbumDTO: Decodable {
        var id: String
        var name: String?
        var title: String?
        var artist: String?
        var artistId: String?
        var coverArt: String?
        var songCount: Int?
        var duration: Int?
        var genre: String?
        var year: Int?
        @LenientArray var song: [SongDTO] = []
    }

    private struct ArtistDTO: Decodable {
        var id: String
        var name: String?
        var coverArt: String?
        var albumCount: Int?
        @LenientArray var album: [AlbumDTO] = []
    }

    private struct PlaylistDTO: Decodable {
        var id: String
        var name: String?
        var songCount: Int?
        var duration: Int?
        var coverArt: String?
        @LenientArray var entry: [SongDTO] = []
    }

    private struct ArtistsPayload: Decodable {
        struct IndexDTO: Decodable {
            var name: String?
            @LenientArray var artist: [ArtistDTO] = []
        }
        struct ArtistsDTO: Decodable {
            var ignoredArticles: String?
            @LenientArray var index: [IndexDTO] = []
        }
        var artists: ArtistsDTO
    }

    private struct ArtistPayload: Decodable { var artist: ArtistDTO }
    private struct AlbumListPayload: Decodable {
        struct ListDTO: Decodable { @LenientArray var album: [AlbumDTO] = [] }
        var albumList2: ListDTO
    }
    private struct AlbumPayload: Decodable { var album: AlbumDTO }
    private struct PlaylistsPayload: Decodable {
        struct ListDTO: Decodable { @LenientArray var playlist: [PlaylistDTO] = [] }
        var playlists: ListDTO
    }
    private struct PlaylistPayload: Decodable { var playlist: PlaylistDTO }
    private struct SearchPayload: Decodable {
        struct ResultDTO: Decodable {
            @LenientArray var artist: [ArtistDTO] = []
            @LenientArray var album: [AlbumDTO] = []
            @LenientArray var song: [SongDTO] = []
        }
        var searchResult3: ResultDTO
    }
    private struct StarredPayload: Decodable {
        struct StarredDTO: Decodable {
            @LenientArray var artist: [ArtistDTO] = []
            @LenientArray var album: [AlbumDTO] = []
            @LenientArray var song: [SongDTO] = []
        }
        var starred2: StarredDTO
    }
    private struct GenresPayload: Decodable {
        struct GenreDTO: Decodable {
            var value: String?
            var songCount: Int?
            var albumCount: Int?
        }
        struct GenresDTO: Decodable { @LenientArray var genre: [GenreDTO] = [] }
        var genres: GenresDTO
    }
    private struct SongListPayload: Decodable {
        struct ListDTO: Decodable { @LenientArray var song: [SongDTO] = [] }
        var randomSongs: ListDTO?
        var similarSongs2: ListDTO?
    }

    // MARK: - Mapping

    private func mapSong(_ dto: SongDTO) -> Song {
        Song(id: dto.id, serverID: serverID,
             title: dto.title ?? "Unknown Title",
             artist: dto.artist ?? "",
             album: dto.album ?? "",
             albumID: dto.albumId ?? "",
             artistID: dto.artistId ?? "",
             coverArtID: dto.coverArt ?? dto.albumId ?? "",
             duration: dto.duration ?? 0,
             isFavourite: dto.starred != nil,
             localFileURL: nil,
             suffix: dto.suffix, bitRate: dto.bitRate,
             genre: dto.genre, year: dto.year)
    }

    private func mapAlbum(_ dto: AlbumDTO) -> Album {
        Album(id: dto.id, serverID: serverID,
              name: dto.name ?? dto.title ?? "Unknown Album",
              artist: dto.artist ?? "",
              artistID: dto.artistId ?? "",
              coverArtID: dto.coverArt ?? dto.id,
              songCount: dto.songCount ?? dto.song.count,
              duration: dto.duration ?? 0,
              year: dto.year, genre: dto.genre)
    }

    private func mapArtist(_ dto: ArtistDTO) -> Artist {
        Artist(id: dto.id, serverID: serverID,
               name: dto.name ?? "Unknown Artist",
               albumCount: dto.albumCount ?? dto.album.count,
               coverArtID: dto.coverArt ?? dto.id)
    }

    private func mapPlaylist(_ dto: PlaylistDTO) -> Playlist {
        Playlist(id: dto.id, serverID: serverID,
                 name: dto.name ?? "Playlist",
                 songCount: dto.songCount ?? dto.entry.count,
                 duration: dto.duration ?? 0,
                 coverArtID: dto.coverArt ?? "",
                 isDownloadSynced: false)
    }

    // MARK: - MusicBackend

    func prepare() async throws {
        let _: EmptyPayload = try await fetch("ping")
    }

    func artists() async throws -> [Artist] {
        let payload: ArtistsPayload = try await fetch("getArtists")
        return payload.artists.index.flatMap { $0.artist }.map(mapArtist)
    }

    func artistAlbums(artistID: String) async throws -> [Album] {
        let payload: ArtistPayload = try await fetch("getArtist", extra: [URLQueryItem(name: "id", value: artistID)])
        return payload.artist.album.map(mapAlbum)
    }

    func albums() async throws -> [Album] {
        let payload: AlbumListPayload = try await fetch("getAlbumList2", extra: [
            URLQueryItem(name: "type", value: "alphabeticalByName"),
            URLQueryItem(name: "size", value: "500")
        ])
        return payload.albumList2.album.map(mapAlbum)
    }

    func albumSongs(albumID: String) async throws -> [Song] {
        let payload: AlbumPayload = try await fetch("getAlbum", extra: [URLQueryItem(name: "id", value: albumID)])
        return payload.album.song.map(mapSong)
    }

    func songs() async throws -> [Song] {
        // The Subsonic API has no "all songs" endpoint; page search3 with an
        // empty query (supported by Navidrome/Subsonic) in 500-song pages.
        var all: [Song] = []
        for offset in [0, 500, 1000] {
            let payload: SearchPayload = try await fetch("search3", extra: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: "500"),
                URLQueryItem(name: "songOffset", value: "\(offset)")
            ])
            let page = payload.searchResult3.song.map(mapSong)
            all.append(contentsOf: page)
            if page.count < 500 { break }
        }
        return all
    }

    func playlists() async throws -> [Playlist] {
        let payload: PlaylistsPayload = try await fetch("getPlaylists")
        return payload.playlists.playlist.map(mapPlaylist)
    }

    func playlistSongs(playlistID: String) async throws -> [Song] {
        let payload: PlaylistPayload = try await fetch("getPlaylist", extra: [URLQueryItem(name: "id", value: playlistID)])
        return payload.playlist.entry.map(mapSong)
    }

    func search(query: String) async throws -> SearchResults {
        let payload: SearchPayload = try await fetch("search3", extra: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "50"),
            URLQueryItem(name: "albumCount", value: "100"),
            URLQueryItem(name: "songCount", value: "200")
        ])
        return SearchResults(artists: payload.searchResult3.artist.map(mapArtist),
                             albums: payload.searchResult3.album.map(mapAlbum),
                             songs: payload.searchResult3.song.map(mapSong))
    }

    func streamURL(for song: Song) -> URL? {
        guard let base = config.baseURLValue, let auth = syncAuthItems() else { return nil }
        var items = auth + [URLQueryItem(name: "id", value: song.id)]
        if let maxBitRateKbps {
            items.append(URLQueryItem(name: "maxBitRate", value: "\(maxBitRateKbps)"))
            items.append(URLQueryItem(name: "format", value: "mp3"))
        }
        var components = URLComponents(
            url: base.appendingPathComponent("rest").appendingPathComponent("stream.view"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = items
        return components?.url
    }

    func artworkURL(coverArtID: String) -> URL? {
        guard !coverArtID.isEmpty, let base = config.baseURLValue, let auth = syncAuthItems() else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("rest").appendingPathComponent("getCoverArt.view"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = auth + [
            URLQueryItem(name: "id", value: coverArtID),
            URLQueryItem(name: "size", value: "600")
        ]
        return components?.url
    }

    func setFavourite(song: Song, favourite: Bool) async throws {
        try await fetchVoid(favourite ? "star" : "unstar",
                            extra: [URLQueryItem(name: "id", value: song.id)])
    }

    func createPlaylist(name: String, songIDs: [String]) async throws {
        var items = [URLQueryItem(name: "name", value: name)]
        for songID in songIDs {
            items.append(URLQueryItem(name: "songId", value: songID))
        }
        try await fetchVoid("createPlaylist", extra: items)
    }

    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        var items = [URLQueryItem(name: "playlistId", value: playlistID)]
        for songID in songIDs {
            items.append(URLQueryItem(name: "songIdToAdd", value: songID))
        }
        try await fetchVoid("updatePlaylist", extra: items)
    }

    func scrobble(song: Song) async throws {
        try await fetchVoid("scrobble", extra: [
            URLQueryItem(name: "id", value: song.id),
            URLQueryItem(name: "submission", value: "true")
        ])
    }

    func genres() async throws -> [String] {
        let payload: GenresPayload = try await fetch("getGenres")
        return payload.genres.genre.compactMap { $0.value }.filter { !$0.isEmpty }
    }

    func albumsByGenre(_ genre: String) async throws -> [Album] {
        let payload: AlbumListPayload = try await fetch("getAlbumList2", extra: [
            URLQueryItem(name: "type", value: "byGenre"),
            URLQueryItem(name: "genre", value: genre),
            URLQueryItem(name: "size", value: "500")
        ])
        return payload.albumList2.album.map(mapAlbum)
    }

    func recentlyAdded(limit: Int) async throws -> [Album] {
        let payload: AlbumListPayload = try await fetch("getAlbumList2", extra: [
            URLQueryItem(name: "type", value: "newest"),
            URLQueryItem(name: "size", value: "\(max(1, limit))")
        ])
        return payload.albumList2.album.map(mapAlbum)
    }

    func randomSongs(limit: Int) async throws -> [Song] {
        let payload: SongListPayload = try await fetch("getRandomSongs", extra: [
            URLQueryItem(name: "size", value: "\(max(1, limit))")
        ])
        return (payload.randomSongs?.song ?? []).map(mapSong)
    }

    func similarSongs(song: Song) async throws -> [Song] {
        let payload: SongListPayload = try await fetch("getSimilarSongs2", extra: [
            URLQueryItem(name: "id", value: song.id),
            URLQueryItem(name: "count", value: "50")
        ])
        var similar = (payload.similarSongs2?.song ?? []).map(mapSong)
        if similar.isEmpty, !song.artistID.isEmpty {
            let fallback: SongListPayload = try await fetch("getSimilarSongs2", extra: [
                URLQueryItem(name: "id", value: song.artistID),
                URLQueryItem(name: "count", value: "50")
            ])
            similar = (fallback.similarSongs2?.song ?? []).map(mapSong)
        }
        return similar.filter { $0.id != song.id }
    }

    func starredSongs() async throws -> [Song] {
        let payload: StarredPayload = try await fetch("getStarred2")
        return payload.starred2.song.map(mapSong)
    }
}
