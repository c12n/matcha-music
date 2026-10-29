//  Lyrics.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Lyrics come from LRCLIB (free, no key). Synced LRC is preferred; plain
//  lyrics come back as unsynced lines with a negative time. Only the track
//  name, artist, album and duration are sent.
import Foundation

struct LyricLine: Identifiable, Hashable {
    var time: Double          // seconds; < 0 means unsynced (plain lyrics)
    var text: String
    var id: Double { time }
    var isSynced: Bool { time >= 0 }
}

enum LyricsService {
    static func fetch(song: Song) async -> [LyricLine] {
        if let lines = await fetchExact(song: song), !lines.isEmpty { return lines }
        return await fetchSearch(song: song)
    }

    /// Index of the line that should be highlighted at `seconds`, or nil
    /// when the lyrics are unsynced or playback is before the first line.
    static func currentLineIndex(lines: [LyricLine], at seconds: Double) -> Int? {
        guard seconds >= 0 else { return nil }
        var current: Int? = nil
        for (index, line) in lines.enumerated() {
            if line.time < 0 { continue }
            if line.time <= seconds { current = index } else { break }
        }
        return current
    }

    // MARK: - LRCLIB

    private struct GetResponse: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }
    private struct SearchItem: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private static func fetchExact(song: Song) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "artist_name", value: song.artist),
            URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "album_name", value: song.album),
            URLQueryItem(name: "duration", value: String(song.duration)),
        ]
        guard let url = comps?.url,
              let (data, response) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let res = try? JSONDecoder().decode(GetResponse.self, from: data) else { return nil }
        return lines(from: res)
    }

    private static func fetchSearch(song: Song) async -> [LyricLine] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "artist_name", value: song.artist),
        ]
        guard let url = comps?.url,
              let (data, response) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let items = try? JSONDecoder().decode([SearchItem].self, from: data) else { return [] }
        if let synced = items.first(where: { ($0.syncedLyrics ?? "").isEmpty == false }),
           let parsed = lines(from: GetResponse(syncedLyrics: synced.syncedLyrics, plainLyrics: synced.plainLyrics)) {
            return parsed
        }
        for item in items {
            if let parsed = lines(from: GetResponse(syncedLyrics: item.syncedLyrics, plainLyrics: item.plainLyrics)) {
                return parsed
            }
        }
        return []
    }

    private static func lines(from res: GetResponse) -> [LyricLine]? {
        if let synced = res.syncedLyrics, !synced.isEmpty {
            let parsed = parseLRC(synced)
            if !parsed.isEmpty { return parsed }
        }
        if let plain = res.plainLyrics, !plain.isEmpty {
            // Unsynced: negative, decreasing times keep the lines in order,
            // keep every `id` unique, and keep time < 0 as the "unsynced"
            // marker currentLineIndex checks for.
            return plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { LyricLine(time: -Double($0.offset + 1), text: $0.element) }
        }
        return nil
    }

    // MARK: - LRC parsing

    private static let lrcRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\](.*)"#)

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let match = lrcRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges >= 5 else { continue }
            let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
            var fraction = 0.0
            let fracRange = match.range(at: 3)
            if fracRange.location != NSNotFound {
                let digits = ns.substring(with: fracRange)
                if let value = Double(digits) {
                    fraction = value / pow(10.0, Double(digits.count))
                }
            }
            let text = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
            lines.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
        }
        return lines.sorted { $0.time < $1.time }
    }
}
