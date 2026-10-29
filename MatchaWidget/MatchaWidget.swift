//  MatchaWidget.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Home Screen (small + medium) and Lock Screen widgets. Everything
//  shown comes from the SharedSnapshot the app writes into the App
//  Group; the widget itself never talks to a server. Timelines refresh
//  every 15 minutes and whenever the app reloads them on track change.
import WidgetKit
import SwiftUI

private let matchaGreen = Color(red: 0.36, green: 0.55, blue: 0.28)

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: SharedSnapshot(
            currentTitle: "A Favourite Song", currentArtist: "An Artist",
            isPlaying: true, favourites: ["Song One", "Song Two"], recent: ["Recent One"]))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: SharedSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedSnapshot.read()
        let entries = [
            SnapshotEntry(date: now, snapshot: snapshot),
            SnapshotEntry(date: now.addingTimeInterval(15 * 60), snapshot: snapshot)
        ]
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct MatchaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: SharedSnapshot? { entry.snapshot }

    @ViewBuilder
    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        case .systemMedium:
            mediumBody
                .containerBackground(for: .widget) { Color(.systemBackground) }
        default:
            smallBody
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
    }

    // MARK: Small

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: (snapshot?.isPlaying ?? false) ? "waveform" : "music.note")
                    .foregroundStyle(matchaGreen)
                Text("Matcha Music")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            if let snapshot, !snapshot.currentTitle.isEmpty {
                Text(snapshot.currentTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(snapshot.currentArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text((snapshot.isPlaying) ? "Now playing" : "Paused")
                    .font(.caption)
                    .foregroundStyle(matchaGreen)
            } else {
                Text("Play something")
                    .font(.headline)
                Text("Your music, from your own servers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: (snapshot?.isPlaying ?? false) ? "waveform" : "music.note")
                        .foregroundStyle(matchaGreen)
                    Text("Now Playing")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if let snapshot, !snapshot.currentTitle.isEmpty {
                    Text(snapshot.currentTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(snapshot.currentArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Nothing playing")
                        .font(.headline)
                    Text("Open Matcha Music to start.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                snapshotList(title: "Favourites", icon: "heart.fill",
                             items: snapshot?.favourites ?? [])
                snapshotList(title: "Recently Played", icon: "clock.fill",
                             items: snapshot?.recent ?? [])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func snapshotList(title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(matchaGreen)
            if items.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(3), id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Lock Screen

    private var accessoryRectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
            VStack(alignment: .leading, spacing: 1) {
                if let snapshot, !snapshot.currentTitle.isEmpty {
                    Text(snapshot.currentTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(snapshot.currentArtist)
                        .font(.caption)
                        .widgetAccentable()
                        .lineLimit(1)
                } else {
                    Text("Matcha Music")
                        .font(.headline)
                    Text("Play something")
                        .font(.caption)
                        .widgetAccentable()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: (snapshot?.isPlaying ?? false) ? "waveform" : "music.note")
        }
    }
}

struct MatchaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MatchaWidget", provider: Provider()) { entry in
            MatchaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Matcha Music")
        .description("What you're playing, your favourites and recent songs.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct MatchaWidgetBundle: WidgetBundle {
    var body: some Widget {
        MatchaWidget()
    }
}
