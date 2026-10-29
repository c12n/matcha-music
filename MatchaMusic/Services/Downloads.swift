//  Downloads.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Offline downloads: files live under Application Support/Downloads/
//  <serverID>/<sanitised native id>.<ext>, with an index.json mapping
//  Song.uid -> the Song (its localFileURL pointing at the file). Downloads
//  are always the original file the server hands out — no transcoding.
import Foundation
import Observation

@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// 0...1 per Song.uid while a download is in flight.
    var progress: [String: Double] = [:]
    /// uid -> Song with localFileURL set, for everything on disk.
    private(set) var downloaded: [String: Song] = [:]
    /// Playlists (by Playlist.uid) the user asked to keep downloaded & in sync.
    var syncedPlaylistIDs: Set<String>

    private static let syncedKey = "matcha.downloads.syncedPlaylists"

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init() {
        syncedPlaylistIDs = Set(UserDefaults.standard.stringArray(forKey: Self.syncedKey) ?? [])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode([String: Song].self, from: data) {
            // Drop entries whose file has gone missing.
            downloaded = index.filter { _, song in
                guard let url = song.localFileURL else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
        }
    }

    // MARK: - Lookup

    func isDownloaded(_ song: Song) -> Bool { downloaded[song.uid] != nil }

    func localURL(for song: Song) -> URL? {
        guard let url = downloaded[song.uid]?.localFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func sanitise(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    private func destination(for song: Song, sourceURL: URL) -> URL {
        let ext: String
        if let suffix = song.suffix, !suffix.isEmpty {
            ext = suffix.lowercased()
        } else if !sourceURL.pathExtension.isEmpty {
            ext = sourceURL.pathExtension.lowercased()
        } else {
            ext = "mp3"
        }
        let dir = directory.appendingPathComponent(Self.sanitise(song.serverID), isDirectory: true)
        return dir.appendingPathComponent(Self.sanitise(song.id) + "." + ext)
    }

    // MARK: - Downloading

    func download(song: Song, url: URL) async {
        if isDownloaded(song) { return }
        let uid = song.uid
        progress[uid] = 0
        defer { progress[uid] = nil }

        let delegate = DownloadTaskDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        delegate.onProgress = { [weak self] value in
            DispatchQueue.main.async { self?.progress[uid] = value }
        }
        do {
            let tempURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                delegate.continuation = continuation
                let task = session.downloadTask(with: BackendUtil.request(url))
                task.resume()
            }
            let dest = destination(for: song, sourceURL: url)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            var stored = song
            stored.localFileURL = dest
            downloaded[uid] = stored
            saveIndex()
        } catch {
            // Failed downloads leave nothing behind; the UI surfaces errors
            // from the caller's own checks, and a retry simply calls again.
        }
    }

    func downloadAlbum(songs: [Song], urlFor: (Song) async -> URL?) async {
        for song in songs {
            if isDownloaded(song) { continue }
            if let url = await urlFor(song) {
                await download(song: song, url: url)
            }
        }
    }

    // MARK: - Removal / storage

    func remove(song: Song) {
        if let url = downloaded[song.uid]?.localFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        downloaded[song.uid] = nil
        saveIndex()
    }

    func removeAll() {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries { try? fm.removeItem(at: entry) }
        }
        downloaded.removeAll()
        progress.removeAll()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func totalBytes() -> Int64 {
        var total: Int64 = 0
        for song in downloaded.values {
            guard let url = song.localFileURL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Playlist sync

    func setPlaylistSynced(_ playlist: Playlist, _ on: Bool) {
        if on { syncedPlaylistIDs.insert(playlist.uid) } else { syncedPlaylistIDs.remove(playlist.uid) }
        UserDefaults.standard.set(Array(syncedPlaylistIDs), forKey: Self.syncedKey)
    }

    func isPlaylistSynced(_ playlist: Playlist) -> Bool {
        syncedPlaylistIDs.contains(playlist.uid)
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(downloaded) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

/// Bridges URLSessionDownloadDelegate callbacks to async/await, reporting
/// progress through a closure. Resumes its continuation exactly once.
private final class DownloadTaskDelegate: NSObject, URLSessionDownloadDelegate {
    var continuation: CheckedContinuation<URL, Error>?
    var onProgress: ((Double) -> Void)?
    private let lock = NSLock()
    private var resumed = false

    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        lock.unlock()
        switch result {
        case .success(let url): continuation?.resume(returning: url)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` as soon as this method returns, so
        // move it aside synchronously.
        let hold = FileManager.default.temporaryDirectory
            .appendingPathComponent("matcha-dl-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: hold)
            finish(with: .success(hold))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(with: .failure(error)) }
    }
}
