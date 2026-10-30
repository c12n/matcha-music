//  Components.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Shared rows and artwork. House rules: a row's main action is ONE tap
//  target (onTapGesture on the whole row or a single Button); the heart
//  and the menu are separate controls next to it — never a Button inside
//  another Button. Content text uses Dynamic Type styles throughout.
import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - Image cache

enum ArtworkImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

// MARK: - On-device artwork

/// Artwork that never leaves the phone: embedded tags for imported
/// files, and the Music library's own artwork for on-device songs.
enum LocalArtwork {
    static func image(serverID: String, itemID: String, localFileURL: URL?) async -> UIImage? {
        let key = "local|\(serverID)|\(itemID)" as NSString
        if let cached = ArtworkImageCache.shared.object(forKey: key) { return cached }
        var image: UIImage?
        if serverID == LocalServerID.files, let url = localFileURL {
            let asset = AVURLAsset(url: url)
            for item in asset.commonMetadata where item.commonKey == .commonKeyArtwork {
                if let data = item.dataValue, let img = UIImage(data: data) {
                    image = img
                    break
                }
            }
        } else if serverID == LocalServerID.library {
            image = await libraryArtwork(itemID: itemID)
        }
        if let image { ArtworkImageCache.shared.setObject(image, forKey: key) }
        return image
    }

    private static func libraryArtwork(itemID: String) async -> UIImage? {
        guard let pid = UInt64(itemID) else { return nil }
        let size = CGSize(width: 600, height: 600)
        // Song first, then album, then artist representative items.
        let songQuery = MPMediaQuery.songs()
        songQuery.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: pid), forProperty: MPMediaItemPropertyPersistentID))
        if let item = songQuery.items?.first, let img = item.artwork?.image(at: size) { return img }
        let albumQuery = MPMediaQuery.albums()
        albumQuery.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: pid), forProperty: MPMediaItemPropertyAlbumPersistentID))
        if let item = albumQuery.collections?.first?.representativeItem,
           let img = item.artwork?.image(at: size) { return img }
        let artistQuery = MPMediaQuery.artists()
        artistQuery.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: pid), forProperty: MPMediaItemPropertyArtistPersistentID))
        if let item = artistQuery.collections?.first?.representativeItem,
           let img = item.artwork?.image(at: size) { return img }
        return nil
    }
}

// MARK: - ArtworkView

/// One artwork view for songs, albums, artists and playlists.
/// Resolution order: on-device artwork → the owning server's artwork →
/// (if enabled in Settings) the Deezer / iTunes / Cover Art Archive
/// fallback chain. `size == nil` means "fill the width, square".
struct ArtworkView: View {
    @Environment(AppModel.self) private var model

    let serverID: String
    let coverArtID: String
    let title: String
    let artist: String
    let album: String
    let localFileURL: URL?
    let localItemID: String
    var size: CGFloat?
    var cornerRadius: CGFloat = 10

    init(song: Song, size: CGFloat? = 54) {
        self.serverID = song.serverID
        self.coverArtID = song.coverArtID
        self.title = song.title
        self.artist = song.artist
        self.album = song.album
        self.localFileURL = song.localFileURL
        self.localItemID = song.id
        self.size = size
    }

    init(album: Album, size: CGFloat? = nil) {
        self.serverID = album.serverID
        self.coverArtID = album.coverArtID
        self.title = album.name
        self.artist = album.artist
        self.album = album.name
        self.localFileURL = nil
        self.localItemID = album.id
        self.size = size
    }

    init(artist: Artist, size: CGFloat? = 54, cornerRadius: CGFloat = 10) {
        self.serverID = artist.serverID
        self.coverArtID = artist.coverArtID
        self.title = artist.name
        self.artist = artist.name
        self.album = ""
        self.localFileURL = nil
        self.localItemID = artist.id
        self.size = size
        self.cornerRadius = cornerRadius
    }

    init(playlist: Playlist, size: CGFloat? = 54) {
        self.serverID = playlist.serverID
        self.coverArtID = playlist.coverArtID
        self.title = playlist.name
        self.artist = ""
        self.album = ""
        self.localFileURL = nil
        self.localItemID = playlist.id
        self.size = size
    }

    private var cacheKey: String { "\(serverID)|\(coverArtID)|\(artist)|\(album)" }

    @State private var image: UIImage?
    @State private var loading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: size == nil ? .infinity : nil)
        .aspectRatio(size == nil ? 1 : nil, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        if let cached = ArtworkImageCache.shared.object(forKey: cacheKey as NSString) {
            image = cached
            return
        }
        loading = true
        defer { loading = false }
        // 1. On-device artwork.
        if let local = await LocalArtwork.image(serverID: serverID, itemID: localItemID, localFileURL: localFileURL) {
            image = local
            ArtworkImageCache.shared.setObject(local, forKey: cacheKey as NSString)
            return
        }
        // 2. The owning server's artwork.
        if !coverArtID.isEmpty,
           let backend = model.backend(for: serverID),
           let url = backend.artworkURL(coverArtID: coverArtID),
           let (data, _) = try? await URLSession.shared.data(for: BackendUtil.request(url)),
           let img = UIImage(data: data) {
            image = img
            ArtworkImageCache.shared.setObject(img, forKey: cacheKey as NSString)
            return
        }
        // 3. Public fallback chain (only artist + album names are sent).
        if model.settings.artworkFallbackEnabled, !album.isEmpty,
           let fallback = await ArtworkResolver.fallbackURL(artist: artist, album: album),
           let (data, _) = try? await URLSession.shared.data(from: fallback),
           let img = UIImage(data: data) {
            image = img
            ArtworkImageCache.shared.setObject(img, forKey: cacheKey as NSString)
        }
    }
}

// MARK: - Format badge

struct FormatBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Song row

/// A song row. Tapping the row plays `song` in the context of `queue`;
/// the heart and the "…" menu are separate controls. In Edit Mode the
/// row is inert so list selection owns the taps.
struct SongRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.editMode) private var editMode

    let song: Song
    var queue: [Song] = []
    var isCurrent: Bool = false
    var showArtwork: Bool = true
    var onAddToPlaylist: ((Song) -> Void)?

    private var isEditing: Bool { editMode?.wrappedValue.isEditing ?? false }
    private var player: PlayerEngine { model.player }

    var body: some View {
        Group {
            if isEditing {
                // In Edit Mode the List owns the taps (multi-select), so
                // the row must not attach its own gesture at all.
                rowContent
            } else {
                rowContent
                    .onTapGesture {
                        Haptics.tap(model.settings)
                        let context = queue.isEmpty ? [song] : queue
                        let start = context.firstIndex { $0.uid == song.uid } ?? 0
                        player.play(songs: context, startIndex: start, model: model)
                    }
            }
        }
        .contextMenu {
            songActions
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if showArtwork {
                ArtworkView(song: song, size: 54)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? model.settings.accent.color : .primary)
                    if let badge = song.formatBadge {
                        FormatBadge(text: badge)
                    }
                    if DownloadManager.shared.isDownloaded(song) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(song.artist)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !song.album.isEmpty {
                    Text(song.album)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(model.settings.accent.color)
            }
            if !song.durationText.isEmpty {
                Text(song.durationText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !isEditing {
                Button {
                    Haptics.strong(model.settings)
                    Task { await model.toggleFavourite(song: song) }
                } label: {
                    Image(systemName: song.isFavourite ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(song.isFavourite ? Color.red : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(song.isFavourite ? "Remove from favourites" : "Add to favourites")

                Menu {
                    songActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(song.title)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var songActions: some View {
        Button {
            player.play(songs: queue.isEmpty ? [song] : queue, startIndex: queue.firstIndex { $0.uid == song.uid } ?? 0, model: model)
        } label: { Label("Play", systemImage: "play.fill") }
        Button {
            player.playNext([song], model: model)
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button {
            player.addToQueue([song])
        } label: { Label("Add to Queue", systemImage: "text.append") }
        Button {
            Task { await model.toggleFavourite(song: song) }
        } label: {
            Label(song.isFavourite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: song.isFavourite ? "heart.slash" : "heart")
        }
        Button {
            Task {
                if let url = await model.url(for: song) {
                    await DownloadManager.shared.download(song: song, url: url)
                }
            }
        } label: { Label("Download", systemImage: "arrow.down.circle") }
        Button {
            Task { await model.startRadio(song: song) }
        } label: { Label("Start Radio", systemImage: "radio") }
        if let onAddToPlaylist {
            Button {
                onAddToPlaylist(song)
            } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        }
    }
}

// MARK: - Other rows

struct AlbumRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(album: album, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(album.artist)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let year = album.year { Text(String(year)) }
                    if album.songCount > 0 { Text("\(album.songCount) songs") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct ArtistRow: View {
    let artist: Artist
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artist: artist, size: 54, cornerRadius: 27)
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if artist.albumCount > 0 {
                    Text("\(artist.albumCount) albums")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(playlist: playlist, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if playlist.songCount > 0 { Text("\(playlist.songCount) songs") }
                    if playlist.isDownloadSynced {
                        Label("Synced", systemImage: "arrow.down.circle.fill")
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Grid cell for album shelves and the Albums screen.
struct AlbumCard: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(album: album, size: nil)
            Text(album.name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(album.artist)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let year = album.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Headers, banners, empty states

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.callout)
            }
        }
    }
}

/// Play + Shuffle header for any song list.
struct PlayAllHeader: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap(model.settings)
                model.player.play(songs: songs, startIndex: 0, model: model)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .glassControl(cornerRadius: 14, tint: model.settings.accent.color.opacity(0.35))
            .buttonStyle(.plain)

            Button {
                Haptics.tap(model.settings)
                model.player.play(songs: songs.shuffled(), startIndex: 0, model: model)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .glassControl(cornerRadius: 14)
            .buttonStyle(.plain)
        }
        .disabled(songs.isEmpty)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if let retry {
                Button("Retry", action: retry)
                    .font(.callout.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Sheet for adding songs to an existing server playlist, or creating a
/// new playlist on the default server with them.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let songs: [Song]
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                if model.displayPlaylists.isEmpty {
                    Text("No playlists yet. Create one below, or from the Playlists tab.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Section("Add to Playlist") {
                        ForEach(model.displayPlaylists) { playlist in
                            Button {
                                Task {
                                    await model.addToPlaylist(playlist, songs: songs)
                                    dismiss()
                                }
                            } label: {
                                PlaylistRow(playlist: playlist)
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let target = model.defaultServer {
                    Section("New Playlist on \(target.name)") {
                        TextField("Playlist name", text: $newPlaylistName)
                            .font(.body)
                        Button("Create & Add") {
                            let name = newPlaylistName
                            Task {
                                let ids = songs.filter { $0.serverID == target.id }.map { $0.id }
                                try? await model.createPlaylist(name: name, songIDs: ids, onServer: target.id)
                                await model.loadLibrary()
                                dismiss()
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
