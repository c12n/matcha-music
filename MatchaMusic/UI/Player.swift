//  Player.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  The playback engine. Deliberately decoupled from AppModel: AppModel
//  installs two closures at init —
//    resolver:       (Song) async -> URL?   (downloaded/local file first,
//                                             then the owning backend's
//                                             stream URL after prepare())
//    onSongFinished: (Song, msPlayed)       (AppModel scrobbles to the
//                                             server / ListenBrainz there)
//  so this file compiles knowing only the Song model.
//
//  Playback uses a single-item AVPlayer: when a track ends the next queue
//  item is loaded. That approximates gapless (the next song's URL is
//  resolved in the background as soon as the current one starts) and is
//  far more robust than juggling AVQueuePlayer items across servers.
import Foundation
import AVFoundation
import MediaPlayer
import Observation

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    // MARK: Queue state (observed by the UI)
    var queue: [Song] = []
    var currentIndex: Int?
    var currentSong: Song?
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var shuffle: Bool = false
    var repeatMode: RepeatMode = .off
    var errorMessage: String?
    var sleepTimerEnd: Date?
    var sleepAtEndOfSong: Bool = false

    // MARK: Installed by AppModel
    var resolver: ((Song) async -> URL?)?
    var onSongFinished: ((Song, Int) -> Void)?

    // MARK: Private playback state
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var loadGeneration = 0
    private var accumulatedSeconds: Double = 0
    private var lastTickTime: Double = 0
    private var reachedEnd = false
    private var sleepTask: Task<Void, Never>?

    private init() {
        player.allowsExternalPlayback = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio still plays with the default session; nothing to show.
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTrackEnd() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleItemFailure() }
        }
        setupRemoteCommands()
    }

    // MARK: - Public controls

    /// Replace the queue and start playing at `startIndex`.
    func play(songs: [Song], startIndex: Int, model: AppModel) {
        guard !songs.isEmpty else { return }
        finalizePlay(finishedNaturally: false)
        queue = songs
        let start = min(max(startIndex, 0), songs.count - 1)
        load(song: songs[start], at: start, autoplay: true)
    }

    /// Jump to an existing queue position (queue pane taps).
    func jump(to index: Int, model: AppModel) {
        guard queue.indices.contains(index), index != currentIndex else {
            if queue.indices.contains(index) { togglePlayPause() }
            return
        }
        finalizePlay(finishedNaturally: false)
        load(song: queue[index], at: index, autoplay: true)
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else if player.currentItem != nil {
            player.play()
            isPlaying = true
        } else if let idx = currentIndex, queue.indices.contains(idx) {
            load(song: queue[idx], at: idx, autoplay: true)
        }
        updateNowPlayingInfo()
    }

    func next() {
        guard let idx = currentIndex else { return }
        advance(from: idx, manual: true)
    }

    func previous() {
        guard let idx = currentIndex else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard idx > 0 else { seek(to: 0); return }
        finalizePlay(finishedNaturally: false)
        load(song: queue[idx - 1], at: idx - 1, autoplay: true)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    /// Queue these songs immediately after the current one.
    func playNext(_ songs: [Song], model: AppModel) {
        guard !songs.isEmpty else { return }
        if let idx = currentIndex {
            queue.insert(contentsOf: songs, at: idx + 1)
        } else {
            queue.append(contentsOf: songs)
            load(song: queue[0], at: 0, autoplay: true)
        }
    }

    func addToQueue(_ songs: [Song]) {
        queue.append(contentsOf: songs)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        if index == currentIndex {
            finalizePlay(finishedNaturally: false)
            queue.remove(at: index)
            if queue.isEmpty {
                stopPlayback()
            } else {
                let nextIdx = min(index, queue.count - 1)
                load(song: queue[nextIdx], at: nextIdx, autoplay: isPlaying)
            }
        } else {
            queue.remove(at: index)
            if let idx = currentIndex, index < idx { currentIndex = idx - 1 }
        }
    }

    /// SwiftUI `.onMove` companion: indices arrive as an IndexSet.
    func moveQueue(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        let moving = source.sorted().map { queue[$0] }
        var reordered = queue
        for i in source.sorted(by: >) { reordered.remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertAt)
        if let idx = currentIndex {
            if source.contains(idx), let first = source.min() {
                currentIndex = insertAt + (idx - first)
            } else {
                var newIdx = idx - source.filter { $0 < idx }.count
                if insertAt <= newIdx { newIdx += moving.count }
                currentIndex = newIdx
            }
        }
        queue = reordered
    }

    func moveQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), destination >= 0, destination < queue.count else { return }
        moveQueue(from: IndexSet(integer: source), to: destination > source ? destination + 1 : destination)
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard shuffle, let idx = currentIndex, queue.count > 2 else { return }
        // Keep the current song where it is; shuffle everything after it.
        let tail = Array(queue[(idx + 1)...]).shuffled()
        queue.replaceSubrange((idx + 1)..., with: tail)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
        guard let minutes, minutes > 0 else { return }
        sleepAtEndOfSong = false
        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.player.pause()
            self?.isPlaying = false
            self?.sleepTimerEnd = nil
            self?.updateNowPlayingInfo()
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
        sleepAtEndOfSong = false
    }

    // MARK: - Retry

    func retry(model: AppModel) {
        guard let idx = currentIndex, queue.indices.contains(idx) else { return }
        errorMessage = nil
        load(song: queue[idx], at: idx, autoplay: true)
    }

    // MARK: - Loading

    private func load(song: Song, at index: Int, autoplay: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        currentIndex = index
        currentSong = song
        currentTime = 0
        duration = Double(song.duration)
        accumulatedSeconds = 0
        lastTickTime = 0
        reachedEnd = false
        errorMessage = nil
        updateNowPlayingInfo()
        Task { [weak self] in
            guard let self else { return }
            let url = await self.resolver?(song)
            guard self.loadGeneration == generation else { return }
            guard let url else {
                self.errorMessage = "Couldn't play this song"
                self.isPlaying = false
                return
            }
            let item = AVPlayerItem(url: url)
            self.player.replaceCurrentItem(with: item)
            if autoplay {
                self.player.play()
                self.isPlaying = true
            }
            self.updateNowPlayingInfo()
            // Pre-resolve the next song so it starts (near-)instantly.
            if let nextIdx = self.nextIndex(after: index) {
                let nextSong = self.queue[nextIdx]
                Task { [weak self] in _ = await self?.resolver?(nextSong) }
            }
        }
    }

    private func nextIndex(after index: Int) -> Int? {
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }

    private func advance(from index: Int, manual: Bool) {
        if !manual, repeatMode == .one {
            // Natural end with Repeat One: count the play, restart.
            finalizePlay(finishedNaturally: true)
            accumulatedSeconds = 0
            reachedEnd = false
            seek(to: 0)
            player.play()
            isPlaying = true
            return
        }
        if let nextIdx = nextIndex(after: index) {
            finalizePlay(finishedNaturally: !manual)
            load(song: queue[nextIdx], at: nextIdx, autoplay: true)
        } else {
            finalizePlay(finishedNaturally: !manual)
            player.pause()
            isPlaying = false
            currentTime = 0
            updateNowPlayingInfo()
        }
    }

    private func stopPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentSong = nil
        currentIndex = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Observers

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        if player.timeControlStatus == .playing {
            let delta = seconds - lastTickTime
            if delta > 0, delta <= 1.5 { accumulatedSeconds += delta }
            isPlaying = true
        } else if player.timeControlStatus == .paused {
            isPlaying = false
        }
        lastTickTime = seconds
        currentTime = seconds
        if let item = player.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
            if item.status == .failed, errorMessage == nil {
                errorMessage = "Couldn't play this song"
                isPlaying = false
            }
        }
    }

    private func handleTrackEnd() {
        guard let idx = currentIndex, !reachedEnd else { return }
        reachedEnd = true
        if sleepAtEndOfSong {
            finalizePlay(finishedNaturally: true)
            sleepAtEndOfSong = false
            player.pause()
            isPlaying = false
            seek(to: 0)
            updateNowPlayingInfo()
            return
        }
        advance(from: idx, manual: false)
    }

    private func handleItemFailure() {
        guard currentSong != nil else { return }
        errorMessage = "Couldn't play this song"
        isPlaying = false
    }

    // MARK: - Play history

    /// Records the play we are leaving behind. A play counts once the
    /// listener heard 30 seconds, or the song finished; the recorded
    /// length is what was actually listened to, capped at the duration.
    private func finalizePlay(finishedNaturally: Bool) {
        guard let song = currentSong else { return }
        let listened = accumulatedSeconds
        guard listened >= 30 || finishedNaturally else { return }
        var ms = Int(listened * 1000)
        if song.duration > 0 { ms = min(ms, song.duration * 1000) }
        PlayHistoryStore.shared.record(song: song, msPlayed: ms)
        onSongFinished?(song, ms)
    }

    // MARK: - Now Playing / remote commands

    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyAlbumTitle] = song.album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player.pause()
                self?.isPlaying = false
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }
}
