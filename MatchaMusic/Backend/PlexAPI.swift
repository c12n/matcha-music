//  PlexAPI.swift — Plex backend + plex.tv PIN auth helpers.
//  Copyright (c) 2026 c12n Apps
//
//  For Plex servers the ServerConfig's baseURL is the chosen connection URI
//  of one plex.tv resource and the Keychain secret is that resource's
//  accessToken (see PlexAuth below for the sign-in flow that produces them).
//  Favourites are modelled with Plex's userRating (rating > 0 == favourite),
//  which is why `starredSongs()` filters the library client-side.
import Foundation

final class PlexAPI: MusicBackend {
    let config: ServerConfig
    var serverID: String { config.id }

    private var cachedSectionKey: String?
    private var cachedMachineIdentifier: String?
    private var genreIDsByName: [String: String] = [:]

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Request plumbing

    private var token: String? {
        KeychainStore.get(KeychainStore.serverSecretAccount(config.id))
    }

    private func makeURL(_ path: String, _ items: [URLQueryItem] = []) throws -> URL {
        let base = try BackendUtil.requireBaseURL(config)
        var baseString = base.absoluteString
        while baseString.hasSuffix("/") { baseString.removeLast() }
        guard var components = URLComponents(string: baseString + path) else {
            throw BackendError.invalidURL
        }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw BackendError.invalidURL }
        return url
    }

    private func request(_ path: String, _ items: [URLQueryItem] = [],
                         method: String = "GET",
                         extraHeaders: [String: String] = [:]) throws -> URLRequest {
        guard let token else { throw BackendError.unauthorized }
        var request = BackendUtil.request(try makeURL(path, items))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(PlexAuth.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Matcha Music", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("1.0.0", forHTTPHeaderField: "X-Plex-Version")
        request.setValue("iPhone", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = [],
                                   extraHeaders: [String: String] = [:]) async throws -> T {
        try await send(try request(path, items, extraHeaders: extraHeaders))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try BackendUtil.checkHTTP(response, context: "Plex")
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
            try BackendUtil.checkHTTP(response, context: "Plex")
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }

    // MARK: - DTOs

    private struct ContainerResponse: Decodable {
        struct Container: Decodable {
            var friendlyName: String?
            var machineIdentifier: String?
            @LenientArray var Directory: [DirectoryDTO] = []
            @LenientArray var Metadata: [MetadataDTO] = []
        }
        var MediaContainer: Container
    }

    private struct DirectoryDTO: Decodable {
        var key: String?
        var id: Int?
        var type: String?
        var title: String?
    }

    private struct MetadataDTO: Decodable {
        var ratingKey: String
        var key: String?
        var type: String?
        var title: String?
        var parentTitle: String?
        var grandparentTitle: String?
        var originalTitle: String?
        var parentRatingKey: String?
        var grandparentRatingKey: String?
        var thumb: String?
        var parentThumb: String?
        var grandparentThumb: String?
        var composite: String?
        var duration: Int?
        var year: Int?
        var leafCount: Int?
        var childCount: Int?
        var userRating: Double?
        var addedAt: Int?
        struct MediaDTO: Decodable {
            var container: String?
            var bitrate: Int?
            struct PartDTO: Decodable { var key: String?; var container: String? }
            @LenientArray var Part: [PartDTO] = []
        }
        @LenientArray var Media: [MediaDTO] = []
        struct GenreDTO: Decodable { var tag: String? }
        @LenientArray var Genre: [GenreDTO] = []
    }

    // MARK: - Mapping

    private func mapSong(_ dto: MetadataDTO) -> Song {
        let media = dto.Media.first
        return Song(id: dto.ratingKey, serverID: serverID,
                    title: dto.title ?? "Unknown Title",
                    artist: dto.grandparentTitle ?? dto.originalTitle ?? "",
                    album: dto.parentTitle ?? "",
                    albumID: dto.parentRatingKey ?? "",
                    artistID: dto.grandparentRatingKey ?? "",
                    coverArtID: dto.thumb ?? dto.parentThumb ?? dto.grandparentThumb ?? "",
                    duration: (dto.duration ?? 0) / 1000,
                    isFavourite: (dto.userRating ?? 0) > 0,
                    localFileURL: nil,
                    suffix: media?.Part.first?.container ?? media?.container,
                    bitRate: media?.bitrate,
                    genre: dto.Genre.first?.tag,
                    year: dto.year)
    }

    private func mapAlbum(_ dto: MetadataDTO) -> Album {
        Album(id: dto.ratingKey, serverID: serverID,
              name: dto.title ?? "Unknown Album",
              artist: dto.parentTitle ?? "",
              artistID: dto.parentRatingKey ?? "",
              coverArtID: dto.thumb ?? "",
              songCount: dto.leafCount ?? dto.childCount ?? 0,
              duration: (dto.duration ?? 0) / 1000,
              year: dto.year, genre: dto.Genre.first?.tag)
    }

    private func mapArtist(_ dto: MetadataDTO) -> Artist {
        Artist(id: dto.ratingKey, serverID: serverID,
               name: dto.title ?? "Unknown Artist",
               albumCount: dto.leafCount ?? dto.childCount ?? 0,
               coverArtID: dto.thumb ?? "")
    }

    private func mapPlaylist(_ dto: MetadataDTO) -> Playlist {
        Playlist(id: dto.ratingKey, serverID: serverID,
                 name: dto.title ?? "Playlist",
                 songCount: dto.leafCount ?? 0,
                 duration: (dto.duration ?? 0) / 1000,
                 coverArtID: dto.composite ?? dto.thumb ?? "",
                 isDownloadSynced: false)
    }

    // MARK: - Server facts

    private func machineIdentifier() async throws -> String {
        if let cachedMachineIdentifier { return cachedMachineIdentifier }
        let response: ContainerResponse = try await get("/identity")
        guard let identifier = response.MediaContainer.machineIdentifier, !identifier.isEmpty else {
            throw BackendError.missingData
        }
        cachedMachineIdentifier = identifier
        return identifier
    }

    private func sectionKey() async throws -> String {
        if let cachedSectionKey { return cachedSectionKey }
        let response: ContainerResponse = try await get("/library/sections")
        guard let section = response.MediaContainer.Directory.first(where: { $0.type == "artist" }),
              let key = section.key ?? section.id.map({ "\($0)" }) else {
            throw BackendError.missingData
        }
        cachedSectionKey = key
        return key
    }

    private func sectionItems(type: Int, extraItems: [URLQueryItem] = [],
                              extraHeaders: [String: String] = [:]) async throws -> [MetadataDTO] {
        let key = try await sectionKey()
        let response: ContainerResponse = try await get(
            "/library/sections/\(key)/all",
            [URLQueryItem(name: "type", value: "\(type)")] + extraItems,
            extraHeaders: extraHeaders)
        return response.MediaContainer.Metadata
    }

    // MARK: - MusicBackend

    func prepare() async throws {
        // /identity both proves reachability/auth and yields the machine id
        // playlist creation needs.
        _ = try await machineIdentifier()
    }

    func artists() async throws -> [Artist] {
        try await sectionItems(type: 8).map(mapArtist)
    }

    func artistAlbums(artistID: String) async throws -> [Album] {
        let response: ContainerResponse = try await get("/library/metadata/\(artistID)/children")
        return response.MediaContainer.Metadata.filter { ($0.type ?? "album") == "album" }.map(mapAlbum)
    }

    func albums() async throws -> [Album] {
        try await sectionItems(type: 9).map(mapAlbum)
    }

    func albumSongs(albumID: String) async throws -> [Song] {
        let response: ContainerResponse = try await get("/library/metadata/\(albumID)/children")
        return response.MediaContainer.Metadata.map(mapSong)
    }

    func songs() async throws -> [Song] {
        try await sectionItems(type: 10).map(mapSong)
    }

    func playlists() async throws -> [Playlist] {
        let response: ContainerResponse = try await get("/playlists", [
            URLQueryItem(name: "playlistType", value: "audio")
        ])
        return response.MediaContainer.Metadata.map(mapPlaylist)
    }

    func playlistSongs(playlistID: String) async throws -> [Song] {
        let response: ContainerResponse = try await get("/playlists/\(playlistID)/items")
        return response.MediaContainer.Metadata.map(mapSong)
    }

    func search(query: String) async throws -> SearchResults {
        let key = try await sectionKey()
        let response: ContainerResponse = try await get("/library/sections/\(key)/search", [
            URLQueryItem(name: "query", value: query)
        ])
        var results = SearchResults()
        for item in response.MediaContainer.Metadata {
            switch item.type ?? "" {
            case "artist": results.artists.append(mapArtist(item))
            case "album": results.albums.append(mapAlbum(item))
            case "track": results.songs.append(mapSong(item))
            default: break
            }
        }
        return results
    }

    func streamURL(for song: Song) -> URL? {
        // A direct part URL can't be built synchronously — the part key only
        // exists in the track's metadata — so playback goes through Plex's
        // universal transcode endpoint. With no bitrate parameters and
        // copyts=1, Plex serves/remuxes audio at original quality in
        // practice; when the user picks a lower streaming quality we pass an
        // explicit audioBitRate cap instead.
        guard token != nil else { return nil }
        var items = [
            URLQueryItem(name: "path", value: "/library/metadata/\(song.id)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "copyts", value: "1")
        ]
        switch UserDefaults.standard.string(forKey: "matcha_streaming_quality") ?? "original" {
        case "high": items.append(URLQueryItem(name: "audioBitrate", value: "320"))
        case "medium": items.append(URLQueryItem(name: "audioBitrate", value: "192"))
        case "low": items.append(URLQueryItem(name: "audioBitrate", value: "128"))
        default: break
        }
        items.append(URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAuth.clientIdentifier))
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        return try? makeURL("/music/:/transcode/universal/start.mp3", items)
    }

    func artworkURL(coverArtID: String) -> URL? {
        // coverArtID holds a thumb path like /library/metadata/123/thumb/1699…
        guard !coverArtID.isEmpty, let token else { return nil }
        return try? makeURL("/photo/:/transcode", [
            URLQueryItem(name: "width", value: "600"),
            URLQueryItem(name: "height", value: "600"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: coverArtID),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ])
    }

    func setFavourite(song: Song, favourite: Bool) async throws {
        try await sendVoid(try request("/:/rate", [
            URLQueryItem(name: "key", value: song.id),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "rating", value: favourite ? "10" : "0")
        ], method: "PUT"))
    }

    private func itemURI(machineID: String, songID: String) -> String {
        "server://\(machineID)/com.plexapp.plugins.library/library/metadata/\(songID)"
    }

    func createPlaylist(name: String, songIDs: [String]) async throws {
        let machineID = try await machineIdentifier()
        var items = [
            URLQueryItem(name: "title", value: name),
            URLQueryItem(name: "type", value: "audio"),
            URLQueryItem(name: "smart", value: "0")
        ]
        if let first = songIDs.first {
            items.append(URLQueryItem(name: "uri", value: itemURI(machineID: machineID, songID: first)))
        }
        let response: ContainerResponse = try await send(try request("/playlists", items, method: "POST"))
        if songIDs.count > 1, let playlistID = response.MediaContainer.Metadata.first?.ratingKey {
            try await addToPlaylist(playlistID: playlistID, songIDs: Array(songIDs.dropFirst()))
        }
    }

    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        let machineID = try await machineIdentifier()
        for songID in songIDs {
            try await sendVoid(try request("/playlists/\(playlistID)/items", [
                URLQueryItem(name: "uri", value: itemURI(machineID: machineID, songID: songID))
            ], method: "PUT"))
        }
    }

    func scrobble(song: Song) async throws {
        // Best-effort; a scrobble failure must never surface.
        guard let request = try? request("/:/scrobble", [
            URLQueryItem(name: "key", value: song.id),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    func genres() async throws -> [String] {
        let key = try await sectionKey()
        let response: ContainerResponse = try await get("/library/sections/\(key)/genre")
        var names: [String] = []
        for entry in response.MediaContainer.Directory {
            guard let title = entry.title, !title.isEmpty else { continue }
            if let genreKey = entry.key ?? entry.id.map({ "\($0)" }) {
                genreIDsByName[title] = genreKey
            }
            names.append(title)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func albumsByGenre(_ genre: String) async throws -> [Album] {
        if genreIDsByName.isEmpty { _ = try await genres() }
        // genres() keys the map by exact title; fall back to a case-insensitive
        // match, then to the genre name itself (some servers accept names).
        let genreID = genreIDsByName[genre]
            ?? genreIDsByName.first(where: { $0.key.lowercased() == genre.lowercased() })?.value
            ?? genre
        return try await sectionItems(type: 9, extraItems: [
            URLQueryItem(name: "genre", value: genreID)
        ]).map(mapAlbum)
    }

    func recentlyAdded(limit: Int) async throws -> [Album] {
        try await sectionItems(
            type: 9,
            extraItems: [URLQueryItem(name: "sort", value: "addedAt:desc")],
            extraHeaders: ["X-Plex-Container-Size": "\(max(1, limit))"]
        ).map(mapAlbum)
    }

    func randomSongs(limit: Int) async throws -> [Song] {
        try await sectionItems(
            type: 10,
            extraItems: [URLQueryItem(name: "sort", value: "random")],
            extraHeaders: ["X-Plex-Container-Size": "\(max(1, limit))"]
        ).map(mapSong)
    }

    func similarSongs(song: Song) async throws -> [Song] {
        var collected: [Song] = []
        var seen: Set<String> = [song.id]

        func absorb(_ candidates: [MetadataDTO]) {
            for dto in candidates {
                let mapped = mapSong(dto)
                if seen.insert(mapped.id).inserted { collected.append(mapped) }
            }
        }

        // Same artist: an artist's grandchildren are its tracks.
        if !song.artistID.isEmpty,
           let response = try? await get("/library/metadata/\(song.artistID)/grandchildren") as ContainerResponse {
            absorb(response.MediaContainer.Metadata)
        }

        // Same genre: resolve the song's genre tag to a section filter id.
        if collected.count < 20, let genreName = song.genre, !genreName.isEmpty {
            if genreIDsByName.isEmpty { _ = try? await genres() }
            if let genreID = genreIDsByName[genreName]
                ?? genreIDsByName.first(where: { $0.key.lowercased() == genreName.lowercased() })?.value {
                if let tracks = try? await sectionItems(type: 10, extraItems: [
                    URLQueryItem(name: "genre", value: genreID)
                ]) {
                    absorb(tracks)
                }
            }
        }
        return Array(collected.shuffled().prefix(50))
    }

    func starredSongs() async throws -> [Song] {
        // Plex has no dedicated favourites list; favourites are tracks the
        // user rated, which mapSong already flags from userRating.
        try await songs().filter { $0.isFavourite }
    }
}

// MARK: - plex.tv PIN sign-in

struct PlexResource: Decodable, Identifiable {
    var name: String
    var product: String?
    var provides: String?
    var clientIdentifier: String?
    var accessToken: String?
    @LenientArray var connections: [Connection] = []
    var id: String { clientIdentifier ?? name }

    struct Connection: Decodable {
        var address: String?
        var port: Int?
        var uri: String
        var local: Bool?
        var relay: Bool?
        var protocolName: String?
        enum CodingKeys: String, CodingKey {
            case address, port, uri, local, relay
            case protocolName = "protocol"
        }
    }

    /// The connection URI to store as a server's baseURL: prefer a
    /// plex.direct URI (works on LAN and remotely over HTTPS), then any
    /// local connection, then the first one offered.
    func bestConnectionURI() -> String? {
        if let direct = connections.first(where: { $0.uri.contains("plex.direct") }) {
            return direct.uri
        }
        if let local = connections.first(where: { $0.local == true }) {
            return local.uri
        }
        return connections.first?.uri
    }
}

enum PlexAuth {
    /// Stable per-install client identifier, shared by the PIN flow and by
    /// every Plex server request.
    static var clientIdentifier: String {
        let key = "matcha.plex.clientID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static func plexTVRequest(path: String, method: String = "GET", token: String? = nil) throws -> URLRequest {
        guard let url = URL(string: "https://plex.tv" + path) else { throw BackendError.invalidURL }
        var request = BackendUtil.request(url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Matcha Music", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("1.0.0", forHTTPHeaderField: "X-Plex-Version")
        request.setValue("iPhone", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }

    private struct PINResponse: Decodable {
        var id: Int
        var code: String
        var authToken: String?
    }

    static func createPIN() async throws -> (id: Int, code: String) {
        let request = try plexTVRequest(path: "/api/v2/pins?strong=true", method: "POST")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try BackendUtil.checkHTTP(response, context: "plex.tv")
            let pin = try JSONDecoder().decode(PINResponse.self, from: data)
            return (pin.id, pin.code)
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }

    /// Returns the auth token once the user has approved the PIN, or nil
    /// while approval is still pending.
    static func pollPIN(id: Int) async throws -> String? {
        let request = try plexTVRequest(path: "/api/v2/pins/\(id)")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try BackendUtil.checkHTTP(response, context: "plex.tv")
            let pin = try JSONDecoder().decode(PINResponse.self, from: data)
            if let token = pin.authToken, !token.isEmpty { return token }
            return nil
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }

    static func authURL(code: String) -> URL {
        // app.plex.tv/auth reads its parameters from the URL fragment.
        let string = "https://app.plex.tv/auth#?clientID=\(clientIdentifier)&code=\(code)&context%5Bdevice%5D%5Bproduct%5D=Matcha%20Music"
        return URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    /// All servers/resources on the account; the caller picks the ones with
    /// provides == "server" and stores each one's accessToken as the secret
    /// for a ServerConfig whose baseURL is bestConnectionURI().
    static func resources(authToken: String) async throws -> [PlexResource] {
        let request = try plexTVRequest(
            path: "/api/v2/resources?includeHttps=1&includeRelay=1", token: authToken)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try BackendUtil.checkHTTP(response, context: "plex.tv")
            return try JSONDecoder().decode([PlexResource].self, from: data)
        } catch let error as BackendError {
            throw error
        } catch let error as DecodingError {
            throw BackendError.server("Couldn't read the plex.tv response. \(error.localizedDescription)")
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
    }
}
