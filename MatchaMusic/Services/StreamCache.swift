//  StreamCache.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  NOTE: AVPlayer streams audio over HTTP and offers no hook to save the
//  bytes it plays, so this cache is populated Downloads-style: when the
//  player pre-fetches a full file for an upcoming track (or a track is
//  fetched ahead of playback), the file lands here via store(fileURL:for:)
//  and later plays start instantly from cachedURL(for:). Permanent offline
//  copies are Downloads' job, not this cache's — the system may also purge
//  Caches at any time, and prune(maxMB:) enforces the user's own cap.
import Foundation

final class StreamCache {
    static let shared = StreamCache()

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StreamCache", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for song: Song) -> URL {
        let ext: String
        if let suffix = song.suffix, !suffix.isEmpty {
            ext = suffix.lowercased()
        } else {
            ext = "mp3"
        }
        return directory.appendingPathComponent(DownloadManager.sanitise(song.uid) + "." + ext)
    }

    /// The cached file for a song, if one was fully fetched earlier.
    func cachedURL(for song: Song) -> URL? {
        let url = fileURL(for: song)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Touch the modification date so LRU pruning treats this as recent.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Copies a fully fetched file into the cache for the song.
    func store(fileURL source: URL, for song: Song) {
        let dest = fileURL(for: song)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    /// Deletes least-recently-used files (oldest modification date first)
    /// until the cache is at or under `maxMB` megabytes.
    func prune(maxMB: Int) {
        let cap = Int64(max(0, maxMB)) * 1_024 * 1_024
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        var sized: [(url: URL, size: Int64, modified: Date)] = entries.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = sized.reduce(Int64(0)) { $0 + $1.size }
        sized.sort { $0.modified < $1.modified }
        for entry in sized {
            if total <= cap { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    func clear() {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries { try? fm.removeItem(at: entry) }
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func currentBytes() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
