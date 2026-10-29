//  Artwork.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  When a server has no artwork for an album, the fallback chain asks, in
//  order: Deezer, iTunes, then Cover Art Archive (via MusicBrainz). Only the
//  artist and album names are ever sent. ArtistInfoService likewise only
//  sends the artist name (Wikipedia biography + Deezer photo / similar
//  artists). ArtworkCache is the shared in-memory + on-disk image cache.
import Foundation
import UIKit
import CryptoKit

enum ArtworkResolver {
    /// First fallback artwork URL for an artist/album pair, or nil.
    static func fallbackURL(artist: String, album: String) async -> URL? {
        if let url = await deezer(artist: artist, album: album) { return url }
        if let url = await itunes(artist: artist, album: album) { return url }
        if let url = await coverArtArchive(artist: artist, album: album) { return url }
        return nil
    }

    // MARK: Deezer

    private struct DeezerAlbumSearch: Decodable {
        struct Item: Decodable { let picture_xl: String? }
        @LenientArray var data: [Item]
    }

    private static func deezer(artist: String, album: String) async -> URL? {
        var comps = URLComponents(string: "https://api.deezer.com/search/album")
        comps?.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(album)")]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let res = try? JSONDecoder().decode(DeezerAlbumSearch.self, from: data),
              let picture = res.data.first?.picture_xl, !picture.isEmpty else { return nil }
        return URL(string: picture)
    }

    // MARK: iTunes

    private struct ITunesSearch: Decodable {
        struct Item: Decodable { let artworkUrl100: String? }
        @LenientArray var results: [Item]
    }

    private static func itunes(artist: String, album: String) async -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let res = try? JSONDecoder().decode(ITunesSearch.self, from: data),
              let artwork = res.results.first?.artworkUrl100, !artwork.isEmpty else { return nil }
        return URL(string: artwork.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    // MARK: MusicBrainz -> Cover Art Archive

    private struct MBReleaseGroupSearch: Decodable {
        struct Group: Decodable { let id: String }
        @LenientArray var releaseGroups: [Group]
        enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
    }

    private static func coverArtArchive(artist: String, album: String) async -> URL? {
        func escaped(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")
        comps?.queryItems = [
            URLQueryItem(name: "query", value: "releasegroup:\"\(escaped(album))\" AND artist:\"\(escaped(artist))\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let res = try? JSONDecoder().decode(MBReleaseGroupSearch.self, from: data),
              let mbid = res.releaseGroups.first?.id else { return nil }
        return URL(string: "https://coverartarchive.org/release-group/\(mbid)/front-500")
    }
}

// MARK: - Image cache

final class ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Artwork", isDirectory: true)
    }

    init() {
        memory.countLimit = 300
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func diskURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex + ".png")
    }

    func image(forKey key: String) -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let url = diskURL(forKey: key)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func store(_ image: UIImage, key: String) {
        memory.setObject(image, forKey: key as NSString)
        if let data = image.pngData() {
            try? data.write(to: diskURL(forKey: key), options: .atomic)
        }
    }
}

// MARK: - Artist info

struct ArtistInfo {
    var bio: String?
    var imageURL: URL?
    var similar: [String]
}

enum ArtistInfoService {
    static func fetch(artist: String) async -> ArtistInfo {
        async let bio = wikipediaBio(artist: artist)
        async let deezer = deezerInfo(artist: artist)
        let d = await deezer
        return ArtistInfo(bio: await bio, imageURL: d.imageURL, similar: d.similar)
    }

    private struct WikiSummary: Decodable { let extract: String? }

    private static func wikipediaBio(artist: String) async -> String? {
        let slug = artist.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
              let (data, _) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let res = try? JSONDecoder().decode(WikiSummary.self, from: data),
              let extract = res.extract, !extract.isEmpty else { return nil }
        return extract
    }

    private struct DeezerArtistSearch: Decodable {
        struct Item: Decodable { let id: Int; let picture_xl: String? }
        @LenientArray var data: [Item]
    }
    private struct DeezerRelated: Decodable {
        struct Item: Decodable { let name: String }
        @LenientArray var data: [Item]
    }

    private static func deezerInfo(artist: String) async -> (imageURL: URL?, similar: [String]) {
        var comps = URLComponents(string: "https://api.deezer.com/search/artist")
        comps?.queryItems = [URLQueryItem(name: "q", value: artist)]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let res = try? JSONDecoder().decode(DeezerArtistSearch.self, from: data),
              let first = res.data.first else { return (nil, []) }
        var similar: [String] = []
        if let relatedURL = URL(string: "https://api.deezer.com/artist/\(first.id)/related"),
           let (rdata, _) = try? await URLSession.shared.data(for: BackendUtil.request(relatedURL)),
           let related = try? JSONDecoder().decode(DeezerRelated.self, from: rdata) {
            similar = related.data.map { $0.name }
        }
        return (first.picture_xl.flatMap { URL(string: $0) }, similar)
    }
}
