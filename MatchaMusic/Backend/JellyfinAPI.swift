//  JellyfinAPI.swift — Jellyfin backend.
//  Copyright (c) 2026 c12n Apps
//
//  Auth: POST /Users/AuthenticateByName with the MediaBrowser authorisation
//  header; the returned access token + user id are cached on the instance by
//  prepare(), which is also what lets the synchronous stream/artwork URLs
//  embed the token. All decoding is lenient — one malformed item never
//  fails a whole list.
import Foundation

final class JellyfinAPI: MusicBackend {
    let config: ServerConfig
    var serverID: String { config.id }

    private var accessToken: String?
    private var userID: String?

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Helpers

    /// Stable per-install device id (not a secret).
    private var deviceID: String {
        let key = "matcha.jellyfin.deviceid"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private func mediaBrowserHeader(token: String?) -> String {
        var header = "MediaBrowser Client=\"Matcha Music\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0.0\""
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    /// Streaming-quality cap in kbps ("original" / unset means no cap).
    private var maxBitRateKbps: Int? {
        switch UserDefaults.standard.string(forKey: "matcha_streaming_quality") ?? "original" {
        case "high": return 320
        case "medium": return 192
        case "low": return 128
        default: return nil
        }
    }

    private func url(_ segments: [String], items: [URLQueryItem] = []) throws -> URL {
        let base = try BackendUtil.requireBaseURL(config)
        var target = base
        for segment in segments { target = target.appendingPathComponent(segment) }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else { throw BackendError.invalidURL }
        return url
    }

    private func authenticatedRequest(_ url: URL) throws -> URLRequest {
        guard let accessToken else { throw BackendError.unauthorized }
        var request = BackendUtil.request(url)
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(mediaBrowserHeader(token: accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try BackendUtil.checkHTTP(response, context: "Jellyfin")
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as BackendError {
            throw error
        } catch let error as DecodingError {
            throw BackendError.server("Couldn't read the server's response. \(error.localizedDescription)")
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }

    private func sendVoid(_ request: URLRequest) async throws {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try BackendUtil.checkHTTP(response, context: "Jellyfin")
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }

    private func get<T: Decodable>(_ segments: [String], items: [URLQueryItem] = []) async throws -> T {
        try await authenticate()
        return try await send(authenticatedRequest(try url(segments, items: items)))
    }

    private func authenticate() async throws {
        if accessToken != nil, userID != nil { return }
        guard let password = KeychainStore.get(KeychainStore.serverSecretAccount(config.id)) else {
            throw BackendError.unauthorized
        }
        let authURL = try url(["Users", "AuthenticateByName"])
        var request = BackendUtil.request(authURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(mediaBrowserHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": config.username,
            "Pw": password
        ])
        struct AuthResponse: Decodable {
            var AccessToken: String
            struct UserDTO: Decodable { var Id: String }
            var User: UserDTO
        }
        let auth: AuthResponse = try await send(request)
        accessToken = auth.AccessToken
        userID = auth.User.Id
    }

    private func requireUserID() throws -> String {
        guard let userID else { throw BackendError.unauthorized }
        return userID
    }

    private var libraryFields: String { "MediaSources,Genres,ProductionYear,ChildCount" }

    private func itemsQuery(_ pairs: [(String, String)]) -> [URLQueryItem] {
        pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
    }

    // MARK: - DTOs

    private struct ItemDTO: Decodable {
        var Id: String
        var Name: String?
        var `Type`: String?
        var Album: String?
        var AlbumId: String?
        @LenientArray var Artists: [String] = []
        var AlbumArtist: String?
        struct NameID: Decodable { var Id: String?; var Name: String? }
        @LenientArray var ArtistItems: [NameID] = []
        var RunTimeTicks: Int64?
        var ProductionYear: Int?
        @LenientArray var Genres: [String] = []
        struct UserDataDTO: Decodable { var IsFavorite: Bool? }
        var UserData: UserDataDTO?
        struct MediaSourceDTO: Decodable { var Container: String?; var Bitrate: Int? }
        @LenientArray var MediaSources: [MediaSourceDTO] = []
        var ChildCount: Int?
    }

    private struct ItemsResponse: Decodable {
        @LenientArray var Items: [ItemDTO] = []
    }

    // MARK: - Mapping

    private func ticksToSeconds(_ ticks: Int64?) -> Int {
        guard let ticks else { return 0 }
        return Int(ticks / 10_000_000)
    }

    private func mapSong(_ dto: ItemDTO) -> Song {
        let source = dto.MediaSources.first
        return Song(id: dto.Id, serverID: serverID,
                    title: dto.Name ?? "Unknown Title",
                    artist: dto.Artists.first ?? dto.AlbumArtist ?? "",
                    album: dto.Album ?? "",
                    albumID: dto.AlbumId ?? "",
                    artistID: dto.ArtistItems.first?.Id ?? "",
                    coverArtID: dto.AlbumId ?? dto.Id,
                    duration: ticksToSeconds(dto.RunTimeTicks),
                    isFavourite: dto.UserData?.IsFavorite ?? false,
                    localFileURL: nil,
                    suffix: source?.Container,
                    bitRate: source?.Bitrate.map { $0 / 1000 },
                    genre: dto.Genres.first, year: dto.ProductionYear)
    }

    private func mapAlbum(_ dto: ItemDTO) -> Album {
        Album(id: dto.Id, serverID: serverID,
              name: dto.Name ?? "Unknown Album",
              artist: dto.AlbumArtist ?? dto.Artists.first ?? "",
              artistID: dto.ArtistItems.first?.Id ?? "",
              coverArtID: dto.Id,
              songCount: dto.ChildCount ?? 0,
              duration: ticksToSeconds(dto.RunTimeTicks),
              year: dto.ProductionYear, genre: dto.Genres.first)
    }

    private func mapArtist(_ dto: ItemDTO) -> Artist {
        Artist(id: dto.Id, serverID: serverID,
               name: dto.Name ?? "Unknown Artist",
               albumCount: dto.ChildCount ?? 0,
               coverArtID: dto.Id)
    }

    private func mapPlaylist(_ dto: ItemDTO) -> Playlist {
        Playlist(id: dto.Id, serverID: serverID,
                 name: dto.Name ?? "Playlist",
                 songCount: dto.ChildCount ?? 0,
                 duration: ticksToSeconds(dto.RunTimeTicks),
                 coverArtID: dto.Id,
                 isDownloadSynced: false)
    }

    // MARK: - MusicBackend

    func prepare() async throws {
        try await authenticate()
    }

    func artists() async throws -> [Artist] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "MusicArtist"), ("Recursive", "true"),
            ("SortBy", "SortName"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapArtist)
    }

    func artistAlbums(artistID: String) async throws -> [Album] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "MusicAlbum"), ("Recursive", "true"),
            ("ArtistIds", artistID), ("SortBy", "ProductionYear,SortName"),
            ("Fields", libraryFields)
        ]))
        return response.Items.map(mapAlbum)
    }

    func albums() async throws -> [Album] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "MusicAlbum"), ("Recursive", "true"),
            ("SortBy", "SortName"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapAlbum)
    }

    func albumSongs(albumID: String) async throws -> [Song] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "Audio"), ("ParentId", albumID), ("Recursive", "true"),
            ("SortBy", "ParentIndexNumber,IndexNumber,SortName"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapSong)
    }

    func songs() async throws -> [Song] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "Audio"), ("Recursive", "true"),
            ("SortBy", "SortName"), ("Limit", "1000"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapSong)
    }

    func playlists() async throws -> [Playlist] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "Playlist"), ("Recursive", "true"),
            ("SortBy", "SortName"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapPlaylist)
    }

    func playlistSongs(playlistID: String) async throws -> [Song] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Playlists", playlistID, "Items"], items: itemsQuery([
            ("UserId", uid), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapSong)
    }

    func search(query: String) async throws -> SearchResults {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("SearchTerm", query), ("IncludeItemTypes", "Audio,MusicAlbum,MusicArtist"),
            ("Recursive", "true"), ("Limit", "200"), ("Fields", libraryFields)
        ]))
        var results = SearchResults()
        for item in response.Items {
            switch item.`Type` ?? "" {
            case "MusicArtist": results.artists.append(mapArtist(item))
            case "MusicAlbum": results.albums.append(mapAlbum(item))
            case "Audio": results.songs.append(mapSong(item))
            default:
                // Some queries omit Type; a song-shaped item (has an album)
                // is the safest guess, everything else is skipped.
                if item.Album != nil || item.AlbumId != nil { results.songs.append(mapSong(item)) }
            }
        }
        return results
    }

    func streamURL(for song: Song) -> URL? {
        guard let base = config.baseURLValue else { return nil }
        if let maxBitRateKbps, let userID {
            var components = URLComponents(
                url: base.appendingPathComponent("Audio").appendingPathComponent(song.id).appendingPathComponent("universal"),
                resolvingAgainstBaseURL: false)
            var items = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "DeviceId", value: deviceID),
                URLQueryItem(name: "Container", value: "mp3"),
                URLQueryItem(name: "AudioCodec", value: "mp3"),
                URLQueryItem(name: "MaxStreamingBitrate", value: "\(maxBitRateKbps * 1000)")
            ]
            if let accessToken { items.append(URLQueryItem(name: "api_key", value: accessToken)) }
            components?.queryItems = items
            return components?.url
        }
        var components = URLComponents(
            url: base.appendingPathComponent("Audio").appendingPathComponent(song.id).appendingPathComponent("stream"),
            resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "static", value: "true")]
        if let accessToken { items.append(URLQueryItem(name: "api_key", value: accessToken)) }
        components?.queryItems = items
        return components?.url
    }

    func artworkURL(coverArtID: String) -> URL? {
        guard !coverArtID.isEmpty, let base = config.baseURLValue else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("Items").appendingPathComponent(coverArtID)
                .appendingPathComponent("Images").appendingPathComponent("Primary"),
            resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "maxWidth", value: "600")]
        if let accessToken { items.append(URLQueryItem(name: "api_key", value: accessToken)) }
        components?.queryItems = items
        return components?.url
    }

    func setFavourite(song: Song, favourite: Bool) async throws {
        try await authenticate()
        let uid = try requireUserID()
        var request = try authenticatedRequest(try url(["Users", uid, "FavoriteItems", song.id]))
        request.httpMethod = favourite ? "POST" : "DELETE"
        try await sendVoid(request)
    }

    func createPlaylist(name: String, songIDs: [String]) async throws {
        try await authenticate()
        let uid = try requireUserID()
        var request = try authenticatedRequest(try url(["Playlists"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "Name": name,
            "Ids": songIDs,
            "UserId": uid,
            "MediaType": "Audio"
        ])
        try await sendVoid(request)
    }

    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        guard !songIDs.isEmpty else { return }
        try await authenticate()
        let uid = try requireUserID()
        var request = try authenticatedRequest(try url(["Playlists", playlistID, "Items"], items: [
            URLQueryItem(name: "Ids", value: songIDs.joined(separator: ",")),
            URLQueryItem(name: "UserId", value: uid)
        ]))
        request.httpMethod = "POST"
        try await sendVoid(request)
    }

    func scrobble(song: Song) async throws {
        // Best-effort "now playing" report; a failure must never surface.
        do {
            try await authenticate()
            var request = try authenticatedRequest(try url(["Sessions", "Playing"]))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["ItemId": song.id])
            _ = try? await URLSession.shared.data(for: request)
        } catch {
            // Ignored by design.
        }
    }

    func genres() async throws -> [String] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Genres"], items: itemsQuery([
            ("UserId", uid), ("SortBy", "SortName")
        ]))
        return response.Items.compactMap { $0.Name }.filter { !$0.isEmpty }
    }

    func albumsByGenre(_ genre: String) async throws -> [Album] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "MusicAlbum"), ("Recursive", "true"),
            ("Genres", genre), ("SortBy", "SortName"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapAlbum)
    }

    func recentlyAdded(limit: Int) async throws -> [Album] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "MusicAlbum"), ("Recursive", "true"),
            ("SortBy", "DateCreated"), ("SortOrder", "Descending"),
            ("Limit", "\(max(1, limit))"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapAlbum)
    }

    func randomSongs(limit: Int) async throws -> [Song] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "Audio"), ("Recursive", "true"),
            ("SortBy", "Random"), ("Limit", "\(max(1, limit))"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapSong)
    }

    func similarSongs(song: Song) async throws -> [Song] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Songs", song.id, "InstantMix"], items: itemsQuery([
            ("UserId", uid), ("Limit", "50"), ("Fields", libraryFields)
        ]))
        return response.Items.map(mapSong).filter { $0.id != song.id }
    }

    func starredSongs() async throws -> [Song] {
        try await authenticate()
        let uid = try requireUserID()
        let response: ItemsResponse = try await get(["Users", uid, "Items"], items: itemsQuery([
            ("IncludeItemTypes", "Audio"), ("Recursive", "true"),
            ("Filters", "IsFavorite"), ("SortBy", "SortName"), ("Fields", libraryFields)
        ]))
        return response.Items.map { song in
            var song = song
            song.isFavourite = true
            return song
        }
    }

}
