//  NowPlaying.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Full-screen player: artwork, scrubber, transport, AirPlay, sleep
//  timer, synced lyrics, the queue, the equalizer, and Save Queue as
//  Playlist. Playback errors are shown with a Retry button — never a
//  dead screen.
import SwiftUI
import AVKit

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showEqualizer = false
    @State private var showSaveQueue = false
    @State private var saveName = ""
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false
    @State private var queueEditMode = EditMode.inactive

    private var player: PlayerEngine { model.player }
    private var song: Song? { player.currentSong }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let song {
                        ArtworkView(song: song, size: 280)
                            .padding(.top, 8)
                        VStack(spacing: 4) {
                            Text(song.title)
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(song.artist)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                            if !song.album.isEmpty {
                                Text(song.album)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        if let error = player.errorMessage {
                            ErrorBanner(message: error) {
                                player.retry(model: model)
                            }
                        }

                        progressSection
                        controlsSection
                        secondarySection

                        if let end = player.sleepTimerEnd {
                            Text("Sleep timer: pauses at \(end.formatted(date: .omitted, time: .shortened))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if player.sleepAtEndOfSong {
                            Text("Sleep timer: pauses at the end of this song")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if showLyrics { lyricsPane(song: song) }
                        if showQueue { queuePane }
                    } else {
                        EmptyStateView(icon: "music.note", title: "Nothing playing",
                                       message: "Pick a song from your library and it will play here.")
                    }
                }
                .padding()
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: song?.uid) { await loadLyrics() }
            .sheet(isPresented: $showEqualizer) { EqualizerScreen() }
            .alert("Save Queue as Playlist", isPresented: $showSaveQueue) {
                TextField("Playlist name", text: $saveName)
                Button("Save") { saveQueueAsPlaylist() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The queue's songs are saved as a new playlist on the current song's server (or your default server).")
            }
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(value: $scrub, in: 0...max(player.duration, 0.01)) { editing in
                isScrubbing = editing
                if !editing { player.seek(to: scrub) }
            }
            .tint(model.settings.accent.color)
            .onAppear { scrub = player.currentTime }
            .onChange(of: player.currentTime) { _, newValue in
                if !isScrubbing { scrub = newValue }
            }
            HStack {
                Text(timeText(player.currentTime))
                Spacer()
                Text("-\(timeText(max(player.duration - player.currentTime, 0)))")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    // MARK: Transport

    private var controlsSection: some View {
        HStack(spacing: 8) {
            transportButton(icon: player.shuffle ? "shuffle.circle.fill" : "shuffle",
                            active: player.shuffle, label: "Shuffle") {
                player.toggleShuffle()
            }
            Spacer()
            transportButton(icon: "backward.fill", label: "Previous") {
                player.previous()
            }
            Button {
                Haptics.tap(model.settings)
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(model.settings.accent.color)
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            transportButton(icon: "forward.fill", label: "Next") {
                player.next()
            }
            Spacer()
            transportButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                            active: player.repeatMode != .off,
                            label: "Repeat: \(player.repeatMode.rawValue)") {
                player.cycleRepeatMode()
            }
        }
    }

    @ViewBuilder
    private func transportButton(icon: String, active: Bool = false, label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(active ? model.settings.accent.color : .primary)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Secondary controls

    private var secondarySection: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 2) {
                RoutePickerView(tint: model.settings.accent.color)
                    .frame(width: 44, height: 44)
                Text("AirPlay").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Menu {
                Button("Off") { player.cancelSleepTimer() }
                ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                }
                Button("End of Song") {
                    player.setSleepTimer(minutes: nil)
                    player.sleepAtEndOfSong = true
                }
            } label: {
                secondaryLabel(icon: "moon.fill", text: "Sleep",
                               active: player.sleepTimerEnd != nil || player.sleepAtEndOfSong)
            }
            .frame(maxWidth: .infinity)

            secondaryButton(icon: "text.quote", text: "Lyrics", active: showLyrics) {
                showLyrics.toggle()
                if showLyrics { Task { await loadLyrics() } }
            }
            secondaryButton(icon: "list.bullet", text: "Queue", active: showQueue) {
                showQueue.toggle()
            }
            secondaryButton(icon: "slider.vertical.3", text: "EQ", active: false) {
                showEqualizer = true
            }
            secondaryButton(icon: "square.and.arrow.down", text: "Save", active: false) {
                saveName = ""
                showSaveQueue = true
            }
        }
    }

    private func secondaryLabel(icon: String, text: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 44, height: 44)
            Text(text).font(.caption2)
        }
        .foregroundStyle(active ? model.settings.accent.color : .secondary)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func secondaryButton(icon: String, text: String, active: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            secondaryLabel(icon: icon, text: text, active: active)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(text)
    }

    private func saveQueueAsPlaylist() {
        let target = song.flatMap { s in model.servers.contains { $0.id == s.serverID } ? s.serverID : nil }
            ?? model.defaultServer?.id
        guard let target else { return }
        let name = saveName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await model.createPlaylist(name: name.isEmpty ? "Saved Queue" : name,
                                               fromQueueSongs: player.queue, onServer: target)
                await model.loadLibrary()
            } catch {
                player.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Lyrics

    private func loadLyrics() async {
        guard let song else { lyrics = []; return }
        guard model.settings.lyricsEnabled, showLyrics else { return }
        lyricsLoading = true
        lyrics = await LyricsService.fetch(song: song)
        lyricsLoading = false
    }

    @ViewBuilder
    private func lyricsPane(song: Song) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Lyrics")
            if !model.settings.lyricsEnabled {
                Text("Lyrics are turned off in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else if lyricsLoading {
                HStack { ProgressView(); Text("Fetching lyrics…").font(.body).foregroundStyle(.secondary) }
            } else if lyrics.isEmpty {
                Text("No lyrics found for this song.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                let current = LyricsService.currentLineIndex(lines: lyrics, at: player.currentTime)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(index == current ? .body.weight(.bold) : .body)
                                    .foregroundStyle(index == current ? model.settings.accent.color : .secondary)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    .onChange(of: current) { _, newIndex in
                        if let newIndex {
                            withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                        }
                    }
                }
            }
            Text("Lyrics come from LRCLIB; only the artist, title and duration are sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Queue

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Up Next")
                Button(queueEditMode.isEditing ? "Done" : "Edit") {
                    queueEditMode = queueEditMode.isEditing ? .inactive : .active
                }
                .font(.callout.weight(.semibold))
            }
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, queued in
                    HStack(spacing: 10) {
                        ArtworkView(song: queued, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queued.title)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(queued.artist)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if index == player.currentIndex {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(model.settings.accent.color)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.jump(to: index, model: model)
                    }
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) {
                        player.removeFromQueue(at: index)
                    }
                }
                .onMove { source, destination in
                    player.moveQueue(from: source, to: destination)
                }
            }
            .listStyle(.plain)
            .frame(height: 320)
            .environment(\.editMode, $queueEditMode)
        }
    }
}

// MARK: - AirPlay route picker

struct RoutePickerView: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(tint)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Equalizer

struct EqualizerScreen: View {
    @Environment(\.dismiss) private var dismiss

    private var eq: EqualizerSettings { EqualizerSettings.shared }

    private let bandLabels = ["60 Hz", "170 Hz", "310 Hz", "600 Hz", "1 kHz", "3 kHz", "6 kHz", "12 kHz"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Equalizer", isOn: Binding(
                        get: { eq.enabled },
                        set: { eq.enabled = $0 }
                    ))
                }
                Section("Presets") {
                    ForEach(EQPreset.presets, id: \.name) { preset in
                        Button {
                            eq.apply(preset: preset)
                        } label: {
                            HStack {
                                Text(preset.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if eq.presetName == preset.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if eq.currentGains.isEmpty {
                    Section("Bands") {
                        Text("No bands available.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Bands") {
                        ForEach(eq.currentGains.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(bandLabels[min(index, bandLabels.count - 1)])
                                        .font(.callout.weight(.semibold))
                                    Spacer()
                                    Text(String(format: "%+.1f dB", eq.currentGains[index]))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: gainBinding(index), in: -12...12, step: 0.5)
                                    .disabled(!eq.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section {
                    Text("The equalizer applies to downloaded songs and music stored on this iPhone. Songs streamed from a server play without it in this version.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func gainBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { eq.currentGains.indices.contains(index) ? Double(eq.currentGains[index]) : 0 },
            set: { newValue in
                var gains = eq.currentGains
                guard gains.indices.contains(index) else { return }
                gains[index] = Float(newValue)
                eq.currentGains = gains
            }
        )
    }
}
