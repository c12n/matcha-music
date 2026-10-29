//  PlayHistory.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  On-device play history, kept as JSON (Application Support/PlayHistory/
//  plays.json). Powers the Stats screens and the mixes: top songs / artists /
//  albums, listening minutes per day for Charts, and "this month in past
//  years". Nothing leaves the phone — server-side scrobbling is separate
//  (ListenBrainz / each backend's scrobble).
import Foundation

struct PlayRecord: Codable, Identifiable {
    var songID: String        // uid: serverID|nativeID
    var serverID: String
    var nativeID: String
    var title: String
    var artist: String
    var album: String
    var albumID: String
    var artistID: String
    var coverArtID: String
    var duration: Int         // seconds
    var playedAt: Date
    var msPlayed: Int
    var id: String { songID + "@" + String(playedAt.timeIntervalSince1970) }

    init(song: Song, msPlayed: Int, playedAt: Date = Date()) {
        self.songID = song.uid
        self.serverID = song.serverID
        self.nativeID = song.id
        self.title = song.title
        self.artist = song.artist
        self.album = song.album
        self.albumID = song.albumID
        self.artistID = song.artistID
        self.coverArtID = song.coverArtID
        self.duration = song.duration
        self.playedAt = playedAt
        self.msPlayed = msPlayed
    }
}

struct SongStat: Identifiable {
    var uid: String
    var title: String
    var artist: String
    var album: String
    var coverArtID: String
    var serverID: String
    var nativeID: String
    var count: Int
    var totalMs: Int
    var lastPlayed: Date
    var firstPlayed: Date
    var id: String { uid }
}

struct ArtistStat: Identifiable {
    var name: String
    var count: Int
    var totalMs: Int
    var coverArtID: String
    var serverID: String
    var id: String { serverID + "|" + name }
}

struct AlbumStat: Identifiable {
    var album: String
    var artist: String
    var count: Int
    var totalMs: Int
    var coverArtID: String
    var serverID: String
    var albumID: String
    var id: String { serverID + "|" + (albumID.isEmpty ? album : albumID) }
}

final class PlayHistoryStore {
    static let shared = PlayHistoryStore()

    private let queue = DispatchQueue(label: "com.c12n.matchamusic.playhistory")
    private var records: [PlayRecord] = []

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PlayHistory", isDirectory: true)
    }
    private var fileURL: URL { directory.appendingPathComponent("plays.json") }

    init() {
        queue.sync { loadLocked() }
    }

    // MARK: - Recording

    func record(song: Song, msPlayed: Int) {
        let rec = PlayRecord(song: song, msPlayed: max(0, msPlayed))
        queue.sync {
            records.append(rec)
            saveLocked()
        }
    }

    func all() -> [PlayRecord] {
        queue.sync { records }
    }

    func playCount(uid: String) -> Int {
        queue.sync { records.reduce(0) { $0 + ($1.songID == uid ? 1 : 0) } }
    }

    func clear() {
        queue.sync {
            records.removeAll()
            saveLocked()
        }
    }

    // MARK: - Aggregates

    private func filtered(since: Date?) -> [PlayRecord] {
        guard let since else { return records }
        return records.filter { $0.playedAt >= since }
    }

    private func songStats(from list: [PlayRecord]) -> [SongStat] {
        var byUID: [String: SongStat] = [:]
        var order: [String] = []
        for r in list {
            if var s = byUID[r.songID] {
                s.count += 1
                s.totalMs += r.msPlayed
                s.lastPlayed = max(s.lastPlayed, r.playedAt)
                s.firstPlayed = min(s.firstPlayed, r.playedAt)
                if s.coverArtID.isEmpty { s.coverArtID = r.coverArtID }
                byUID[r.songID] = s
            } else {
                byUID[r.songID] = SongStat(
                    uid: r.songID, title: r.title, artist: r.artist, album: r.album,
                    coverArtID: r.coverArtID, serverID: r.serverID, nativeID: r.nativeID,
                    count: 1, totalMs: r.msPlayed, lastPlayed: r.playedAt, firstPlayed: r.playedAt)
                order.append(r.songID)
            }
        }
        return order.compactMap { byUID[$0] }
    }

    func topSongs(limit: Int, since: Date? = nil) -> [SongStat] {
        queue.sync {
            songStats(from: filtered(since: since))
                .sorted { ($0.count, $0.totalMs, $0.lastPlayed) > ($1.count, $1.totalMs, $1.lastPlayed) }
                .prefix(limit).map { $0 }
        }
    }

    func topArtists(limit: Int, since: Date? = nil) -> [ArtistStat] {
        queue.sync {
            var byKey: [String: ArtistStat] = [:]
            for r in filtered(since: since) where !r.artist.isEmpty {
                let key = r.serverID + "|" + r.artist
                if var s = byKey[key] {
                    s.count += 1
                    s.totalMs += r.msPlayed
                    if s.coverArtID.isEmpty { s.coverArtID = r.coverArtID }
                    byKey[key] = s
                } else {
                    byKey[key] = ArtistStat(name: r.artist, count: 1, totalMs: r.msPlayed, coverArtID: r.coverArtID, serverID: r.serverID)
                }
            }
            return byKey.values
                .sorted { ($0.count, $0.totalMs) > ($1.count, $1.totalMs) }
                .prefix(limit).map { $0 }
        }
    }

    func topAlbums(limit: Int, since: Date? = nil) -> [AlbumStat] {
        queue.sync {
            var byKey: [String: AlbumStat] = [:]
            for r in filtered(since: since) where !r.album.isEmpty {
                let key = r.serverID + "|" + (r.albumID.isEmpty ? r.album : r.albumID)
                if var s = byKey[key] {
                    s.count += 1
                    s.totalMs += r.msPlayed
                    if s.coverArtID.isEmpty { s.coverArtID = r.coverArtID }
                    byKey[key] = s
                } else {
                    byKey[key] = AlbumStat(album: r.album, artist: r.artist, count: 1, totalMs: r.msPlayed, coverArtID: r.coverArtID, serverID: r.serverID, albumID: r.albumID)
                }
            }
            return byKey.values
                .sorted { ($0.count, $0.totalMs) > ($1.count, $1.totalMs) }
                .prefix(limit).map { $0 }
        }
    }

    /// Listening minutes for each of the last `days` days (oldest first,
    /// today last), ready for a Swift Charts bar/area mark.
    func minutesPerDay(days: Int) -> [(day: Date, minutes: Double)] {
        queue.sync {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            var msByDay: [Date: Int] = [:]
            for r in records { msByDay[cal.startOfDay(for: r.playedAt), default: 0] += r.msPlayed }
            return (0..<max(1, days)).reversed().map { offset in
                let day = cal.date(byAdding: .day, value: -offset, to: today) ?? today
                return (day: day, minutes: Double(msByDay[day] ?? 0) / 60_000.0)
            }
        }
    }

    func totalStats(since: Date? = nil) -> (plays: Int, ms: Int, uniqueSongs: Int, uniqueArtists: Int) {
        queue.sync {
            let list = filtered(since: since)
            return (
                plays: list.count,
                ms: list.reduce(0) { $0 + $1.msPlayed },
                uniqueSongs: Set(list.map { $0.songID }).count,
                uniqueArtists: Set(list.map { $0.artist }).count
            )
        }
    }

    /// Raw plays whose month/day match today's, from earlier years.
    func playsOnThisDayInPastYears() -> [PlayRecord] {
        queue.sync {
            let cal = Calendar.current
            let now = cal.dateComponents([.month, .day, .year], from: Date())
            return records.filter { r in
                let c = cal.dateComponents([.month, .day, .year], from: r.playedAt)
                return c.month == now.month && c.day == now.day && (c.year ?? 0) < (now.year ?? 0)
            }
        }
    }

    /// "A year ago this month": top songs played in the current calendar
    /// month in any earlier year.
    func fromThisMonthInPastYears() -> [SongStat] {
        queue.sync {
            let cal = Calendar.current
            let now = cal.dateComponents([.month, .year], from: Date())
            let list = records.filter { r in
                let c = cal.dateComponents([.month, .year], from: r.playedAt)
                return c.month == now.month && (c.year ?? 0) < (now.year ?? 0)
            }
            return songStats(from: list)
                .sorted { ($0.count, $0.totalMs) > ($1.count, $1.totalMs) }
        }
    }

    // MARK: - Persistence (call only on `queue`)

    private func loadLocked() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([PlayRecord].self, from: data) {
            records = decoded
        }
    }

    private func saveLocked() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
