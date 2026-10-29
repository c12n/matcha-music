//  Models.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
import Foundation

enum ServerType: String, Codable, CaseIterable, Identifiable {
    case subsonic, jellyfin, plex
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .subsonic: return "Navidrome / Subsonic"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        }
    }
    var symbol: String {
        switch self {
        case .subsonic: return "server.rack"
        case .jellyfin: return "play.rectangle.on.rectangle"
        case .plex: return "triangle.fill"
        }
    }
}

struct ServerConfig: Codable, Hashable, Identifiable {
    var id: String            // UUID string, stable per saved server
    var name: String
    var type: ServerType
    var baseURL: String       // e.g. http://192.168.1.10:4533 or https://music.example.com
    var username: String
    var isDefault: Bool
    var baseURLValue: URL? { URL(string: baseURL) }
    static func make(name: String, type: ServerType, baseURL: String, username: String, isDefault: Bool) -> ServerConfig {
        ServerConfig(id: UUID().uuidString, name: name, type: type, baseURL: baseURL, username: username, isDefault: isDefault)
    }
}

/// Well-known pseudo server IDs for the two on-device sources.
enum LocalServerID {
    static let library = "local-library"
    static let files = "local-files"
}

struct Song: Codable, Hashable, Identifiable {
    var id: String            // backend-native id (unique within its server only)
    var serverID: String      // ServerConfig.id or a LocalServerID
    var title: String
    var artist: String
    var album: String
    var albumID: String
    var artistID: String
    var coverArtID: String    // backend artwork id/path, "" when none
    var duration: Int         // seconds
    var isFavourite: Bool
    var localFileURL: URL?    // set for local library / local files / downloads
    var suffix: String?       // e.g. "flac", "mp3"
    var bitRate: Int?         // kbps
    var genre: String?
    var year: Int?
    var uid: String { serverID + "|" + id }
    var formatBadge: String? {
        guard let suffix, !suffix.isEmpty else { return nil }
        if let bitRate, bitRate > 0 { return "\(suffix.uppercased()) \(bitRate)k" }
        return suffix.uppercased()
    }
    var durationText: String {
        guard duration > 0 else { return "" }
        return "\(duration / 60):\(String(format: "%02d", duration % 60))"
    }
}

struct Album: Codable, Hashable, Identifiable {
    var id: String
    var serverID: String
    var name: String
    var artist: String
    var artistID: String
    var coverArtID: String
    var songCount: Int
    var duration: Int
    var year: Int?
    var genre: String?
    var uid: String { serverID + "|" + id }
}

struct Artist: Codable, Hashable, Identifiable {
    var id: String
    var serverID: String
    var name: String
    var albumCount: Int
    var coverArtID: String
    var uid: String { serverID + "|" + id }
}

struct Playlist: Codable, Hashable, Identifiable {
    var id: String
    var serverID: String
    var name: String
    var songCount: Int
    var duration: Int
    var coverArtID: String
    var isDownloadSynced: Bool
    var uid: String { serverID + "|" + id }
}

struct SearchResults {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

enum BackendError: LocalizedError {
    case network(String)
    case server(String)
    case invalidURL
    case unauthorized
    case unsupported
    case missingData
    var errorDescription: String? {
        switch self {
        case .network(let m): return m
        case .server(let m): return m
        case .invalidURL: return "That server address isn't valid."
        case .unauthorized: return "Sign-in failed. Check the username and password, or remove and re-add the server."
        case .unsupported: return "This server doesn't support that."
        case .missingData: return "The server returned empty or unrecognised data."
        }
    }
}

/// Lenient list decoding: one malformed element never fails the whole list.
@propertyWrapper
struct LenientArray<T: Decodable>: Decodable {
    var wrappedValue: [T]
    init(wrappedValue: [T]) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) { elements.append(value) }
            else { _ = try? container.decode(Throwaway.self) }
        }
        wrappedValue = elements
    }
    private struct Throwaway: Decodable {
        init(from decoder: Decoder) throws {
            if var u = try? decoder.unkeyedContainer() { while !u.isAtEnd { _ = try? u.decode(Throwaway.self) }; return }
            if let k = try? decoder.container(keyedBy: AnyKey.self) { for key in k.allKeys { _ = try? k.decode(Throwaway.self, forKey: key) }; return }
            var s = try decoder.singleValueContainer()
            if (try? s.decode(String.self)) != nil { return }
            if (try? s.decode(Double.self)) != nil { return }
            if (try? s.decode(Bool.self)) != nil { return }
            try s.decodeNil()
        }
        struct AnyKey: CodingKey { var stringValue: String; var intValue: Int?; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
    }
}
extension LenientArray: Equatable where T: Equatable {}
extension LenientArray: Hashable where T: Hashable {}
