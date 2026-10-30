//  ContentView.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Root layout + Home, Library and all library screens. Layout is chosen
//  by DEVICE IDIOM (Viu rule): iPad gets a split view, iPhone a tab bar —
//  never by size class, so rotation never rebuilds the player.
import SwiftUI
import Charts
import UniformTypeIdentifiers

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    @State private var section: AppSection = .home

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if isPad {
                NavigationSplitView {
                    List {
                        ForEach(AppSection.allCases) { item in
                            Button {
                                section = item
                            } label: {
                                Label(item.label, systemImage: item.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(section == item ? Color.accentColor.opacity(0.18) : Color.clear)
                        }
                    }
                    .navigationTitle("Matcha Music")
                } detail: {
                    NavigationStack {
                        sectionView(section)
                    }
                    .id(section)
                }
                .safeAreaInset(edge: .bottom) { miniPlayer }
            } else {
                TabView {
                    NavigationStack { HomeView() }
                        .tabItem { Label("Home", systemImage: "house.fill") }
                    NavigationStack { LibraryView() }
                        .tabItem { Label("Library", systemImage: "music.note.list") }
                    NavigationStack { SearchScreen() }
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    NavigationStack { FavouritesScreen() }
                        .tabItem { Label("Favourites", systemImage: "heart.fill") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
                .safeAreaInset(edge: .bottom) { miniPlayer }
            }
        }
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .dynamicTypeSize(model.settings.textSize.dynamicTypeSize)
        .tint(model.settings.accent.color)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
        .task {
            await model.loadLibrary()
            model.consumePendingShortcutCommand()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.consumePendingShortcutCommand()
                model.writeSnapshot()
            }
        }
    }

    private var miniPlayer: some View {
        Group {
            if model.player.currentSong != nil {
                MiniPlayerBar { showNowPlaying = true }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .home: HomeView()
        case .albums: AlbumsScreen()
        case .artists: ArtistsScreen()
        case .songs: SongsScreen()
        case .playlists: PlaylistsScreen()
        case .genres: GenresScreen()
        case .decades: DecadesScreen()
        case .search: SearchScreen()
        case .favourites: FavouritesScreen()
        case .downloads: DownloadsScreen()
        case .stats: StatsScreen()
        case .localFiles: LocalFilesScreen()
        case .settings: SettingsView()
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home, albums, artists, songs, playlists, genres, decades, search, favourites, downloads, stats, localFiles, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "Home"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
        case .genres: return "Genres"
        case .decades: return "By Decade"
        case .search: return "Search"
        case .favourites: return "Favourites"
        case .downloads: return "Downloads"
        case .stats: return "Stats"
        case .localFiles: return "Local Files"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .albums: return "square.stack.fill"
        case .artists: return "person.2.fill"
        case .songs: return "music.note"
        case .playlists: return "list.bullet"
        case .genres: return "tag.fill"
        case .decades: return "calendar"
        case .search: return "magnifyingglass"
        case .favourites: return "heart.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .stats: return "chart.bar.fill"
        case .localFiles: return "folder.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Mini player

struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    var onTap: () -> Void

    var body: some View {
        if let song = model.player.currentSong {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    model.player.togglePlayPause()
                } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")
                Button {
                    model.player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next song")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassControl(cornerRadius: 18, tint: model.settings.accent.color.opacity(0.25))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var recentAlbums: [Album] = []
    @State private var randomPicks: [Song] = []

    private var historyStats: [SongStat] {
        PlayHistoryStore.shared.topSongs(limit: 100_000, since: .distantPast)
    }

    private var forgottenFavourites: [Song] {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        let lastPlayed = Dictionary(uniqueKeysWithValues: historyStats.map { ($0.uid, $0.lastPlayed) })
        return model.favourites.filter { song in
            guard let date = lastPlayed[song.uid] else { return true }
            return date < cutoff
        }
    }

    private var neverPlayed: [Song] {
        let played = Set(historyStats.map { $0.uid })
        return Array(model.displaySongs.filter { !played.contains($0.uid) }.prefix(50))
    }

    private var leastPlayed: [Song] {
        historyStats
            .sorted { $0.count < $1.count }
            .compactMap { model.song(byUID: $0.uid) }
            .prefix(50)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = model.loadError {
                    ErrorBanner(message: error) {
                        Task { await model.loadLibrary() }
                    }
                }
                if model.isLoading && model.songs.isEmpty {
                    HStack { ProgressView(); Text("Loading your library…").font(.body).foregroundStyle(.secondary) }
                }
                if model.servers.isEmpty && model.songs.isEmpty && !model.isLoading {
                    EmptyStateView(
                        icon: "music.note.house",
                        title: "Add your music",
                        message: "Add a Navidrome / Subsonic, Jellyfin or Plex server in Settings → Servers, allow access to your Music library, or import audio files from the Files app."
                    )
                }

                let recent = model.recentSongs(limit: 10)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Recently Played")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recent) { song in
                                    SongCard(song: song, queue: recent)
                                }
                            }
                        }
                    }
                }

                if !recentAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Recently Added")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recentAlbums) { album in
                                    NavigationLink {
                                        AlbumScreen(album: album)
                                    } label: {
                                        AlbumCard(album: album)
                                            .frame(width: 150)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if !randomPicks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Random Picks", actionTitle: "Shuffle All") {
                            model.player.play(songs: model.displaySongs.shuffled(), startIndex: 0, model: model)
                        }
                        ForEach(randomPicks) { song in
                            SongRow(song: song, queue: randomPicks,
                                    isCurrent: model.player.currentSong?.uid == song.uid)
                            Divider()
                        }
                    }
                }

                if !model.favourites.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Favourites")
                        ForEach(model.favourites.prefix(5)) { song in
                            SongRow(song: song, queue: model.favourites,
                                    isCurrent: model.player.currentSong?.uid == song.uid)
                            Divider()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Mixes")
                    mixLink("Forgotten Favourites", icon: "heart.slash", songs: forgottenFavourites,
                            emptyText: "No forgotten favourites right now.")
                    mixLink("Never Played", icon: "sparkles", songs: neverPlayed,
                            emptyText: "Everything here has been played at least once.")
                    mixLink("Least Played", icon: "arrow.down.to.line", songs: leastPlayed,
                            emptyText: "Play some songs first and this mix will fill up.")
                }

                if !model.genres.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Genres")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.genres, id: \.self) { genre in
                                    NavigationLink {
                                        GenreScreen(genre: genre)
                                    } label: {
                                        Text(genre)
                                            .font(.callout.weight(.semibold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .glassControl(cornerRadius: 20)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Home")
        .refreshable { await model.loadLibrary() }
        .task {
            recentAlbums = await model.recentlyAdded()
            if randomPicks.isEmpty {
                randomPicks = Array(model.displaySongs.shuffled().prefix(8))
            }
        }
    }

    @ViewBuilder
    private func mixLink(_ title: String, icon: String, songs: [Song], emptyText: String) -> some View {
        if songs.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(emptyText).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            NavigationLink {
                SongListScreen(title: title, songs: songs)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(model.settings.accent.color)
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Spacer()
                    Text("\(songs.count) songs").font(.callout).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Compact card used on Home shelves.
struct SongCard: View {
    @Environment(AppModel.self) private var model
    let song: Song
    var queue: [Song] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(song: song, size: 130)
            Text(song.title)
                .font(.headline)
                .lineLimit(1)
            Text(song.artist)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap(model.settings)
            let context = queue.isEmpty ? [song] : queue
            model.player.play(songs: context, startIndex: context.firstIndex { $0.uid == song.uid } ?? 0, model: model)
        }
    }
}

/// A plain titled song list — used for mixes and other generated lists.
struct SongListScreen: View {
    @Environment(AppModel.self) private var model
    let title: String
    let songs: [Song]
    @State private var playlistTarget: Song?

    var body: some View {
        List {
            Section {
                PlayAllHeader(songs: songs)
            }
            Section {
                ForEach(songs) { song in
                    SongRow(song: song, queue: songs,
                            isCurrent: model.player.currentSong?.uid == song.uid,
                            onAddToPlaylist: { playlistTarget = $0 })
                }
            }
        }
        .navigationTitle(title)
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }
}

// MARK: - Library root

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                entry("Albums", icon: "square.stack.fill", count: model.displayAlbums.count) { AlbumsScreen() }
                entry("Artists", icon: "person.2.fill", count: model.displayArtists.count) { ArtistsScreen() }
                entry("Songs", icon: "music.note", count: model.displaySongs.count) { SongsScreen() }
                entry("Playlists", icon: "list.bullet", count: model.displayPlaylists.count) { PlaylistsScreen() }
                entry("Genres", icon: "tag.fill", count: model.genres.count) { GenresScreen() }
                entry("By Decade", icon: "calendar", count: nil) { DecadesScreen() }
            }
            Section {
                entry("Downloads", icon: "arrow.down.circle.fill",
                      count: DownloadManager.shared.downloaded.count) { DownloadsScreen() }
                entry("Stats", icon: "chart.bar.fill", count: nil) { StatsScreen() }
                entry("Local Files", icon: "folder.fill",
                      count: model.songs.filter { $0.serverID == LocalServerID.files }.count) { LocalFilesScreen() }
            }
            if let error = model.loadError {
                Section {
                    ErrorBanner(message: error) { Task { await model.loadLibrary() } }
                }
            }
        }
        .navigationTitle("Library")
        .refreshable { await model.loadLibrary() }
    }

    @ViewBuilder
    private func entry<Destination: View>(_ title: String, icon: String, count: Int?,
                                          @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: icon)
                    .font(.body)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Albums

struct AlbumsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            if model.displayAlbums.isEmpty {
                EmptyStateView(icon: "square.stack", title: "No albums yet",
                               message: "Albums from your default server and this iPhone will appear here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(model.displayAlbums) { album in
                            NavigationLink {
                                AlbumScreen(album: album)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort Albums", selection: $settings.albumSort) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .refreshable { await model.loadLibrary() }
    }
}

struct AlbumScreen: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var playlistTarget: Song?

    private var allDownloaded: Bool {
        !songs.isEmpty && songs.allSatisfy { DownloadManager.shared.isDownloaded($0) }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(album: album, size: 200)
                    Text(album.name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(album.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let year = album.year { Text(String(year)) }
                        if let genre = album.genre, !genre.isEmpty { Text(genre) }
                        if album.songCount > 0 { Text("\(album.songCount) songs") }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    PlayAllHeader(songs: songs)
                    HStack(spacing: 12) {
                        Button {
                            Task { await model.downloadAlbumSongs(songs) }
                        } label: {
                            Label(allDownloaded ? "Downloaded" : "Download",
                                  systemImage: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .glassControl(cornerRadius: 12)
                        .buttonStyle(.plain)
                        .disabled(songs.isEmpty || allDownloaded)

                        Button {
                            model.player.addToQueue(songs)
                        } label: {
                            Label("Add to Queue", systemImage: "text.append")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .glassControl(cornerRadius: 12)
                        .buttonStyle(.plain)
                        .disabled(songs.isEmpty)
                    }
                    if let first = songs.first {
                        Button {
                            Task { await model.startRadio(song: first) }
                        } label: {
                            Label("Start Radio from this Album", systemImage: "radio")
                                .font(.callout.weight(.semibold))
                        }
                        .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }
            Section {
                if loading {
                    HStack { ProgressView(); Text("Loading songs…").font(.body).foregroundStyle(.secondary) }
                }
                ForEach(songs) { song in
                    SongRow(song: song, queue: songs,
                            isCurrent: model.player.currentSong?.uid == song.uid,
                            onAddToPlaylist: { playlistTarget = $0 })
                }
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.uid) {
            loading = true
            songs = await model.albumSongs(album)
            loading = false
        }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }
}

// MARK: - Artists

struct ArtistsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.displayArtists.isEmpty {
                EmptyStateView(icon: "person.2", title: "No artists yet",
                               message: "Artists from your default server and this iPhone will appear here.")
            } else {
                List {
                    ForEach(model.displayArtists) { artist in
                        NavigationLink {
                            ArtistScreen(artist: artist)
                        } label: {
                            ArtistRow(artist: artist)
                        }
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .refreshable { await model.loadLibrary() }
    }
}

struct ArtistScreen: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    @State private var albums: [Album] = []
    @State private var topSongs: [Song] = []
    @State private var info: ArtistInfo?
    @State private var playlistTarget: Song?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 10) {
                    if let url = info?.imageURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                ArtworkView(artist: artist, size: 110, cornerRadius: 55)
                            }
                        }
                        .frame(width: 110, height: 110)
                        .clipShape(Circle())
                    } else {
                        ArtworkView(artist: artist, size: 110, cornerRadius: 55)
                    }
                    Text(artist.name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let bio = info?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                if let similar = info?.similar, !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Similar Artists")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(similar, id: \.self) { name in
                                    Text(name)
                                        .font(.callout.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .glassControl(cornerRadius: 18)
                                }
                            }
                        }
                    }
                }

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Albums")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                            ForEach(albums) { album in
                                NavigationLink {
                                    AlbumScreen(album: album)
                                } label: {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Songs")
                        ForEach(topSongs) { song in
                            SongRow(song: song, queue: topSongs,
                                    isCurrent: model.player.currentSong?.uid == song.uid,
                                    onAddToPlaylist: { playlistTarget = $0 })
                            Divider()
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.uid) {
            albums = await model.artistAlbums(artist)
            info = await ArtistInfoService.fetch(artist: artist.name)
            var collected: [Song] = []
            for album in albums.prefix(4) {
                collected.append(contentsOf: await model.albumSongs(album))
                if collected.count >= 40 { break }
            }
            topSongs = Array(collected.prefix(40))
        }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }
}

// MARK: - Songs

struct SongsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var editMode = EditMode.inactive
    @State private var batchForPlaylist: SongBatch?

    private struct SongBatch: Identifiable {
        let id = UUID()
        let songs: [Song]
    }

    private var filtered: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.displaySongs }
        return model.displaySongs.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.album.lowercased().contains(q)
        }
    }

    private var selectedSongs: [Song] {
        model.displaySongs.filter { selection.contains($0.uid) }
    }

    var body: some View {
        @Bindable var settings = model.settings
        List(selection: $selection) {
            ForEach(filtered) { song in
                SongRow(song: song, queue: filtered,
                        isCurrent: model.player.currentSong?.uid == song.uid,
                        onAddToPlaylist: { batchForPlaylist = SongBatch(songs: [$0]) })
                    .tag(song.uid)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Songs")
        .searchable(text: $query, prompt: "Search your songs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort Songs", selection: $settings.songSort) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing && !selection.isEmpty {
                batchBar
            }
        }
        .sheet(item: $batchForPlaylist) { batch in
            AddToPlaylistSheet(songs: batch.songs)
        }
        .refreshable { await model.loadLibrary() }
    }

    private var batchBar: some View {
        HStack(spacing: 8) {
            batchButton("Favourite", icon: "heart") {
                let targets = selectedSongs.filter { !$0.isFavourite }
                Task { for song in targets { await model.toggleFavourite(song: song) } }
            }
            batchButton("Download", icon: "arrow.down.circle") {
                let targets = selectedSongs
                Task {
                    for song in targets {
                        if let url = await model.url(for: song) {
                            await DownloadManager.shared.download(song: song, url: url)
                        }
                    }
                }
            }
            batchButton("Playlist", icon: "text.badge.plus") {
                batchForPlaylist = SongBatch(songs: selectedSongs)
            }
            batchButton("Done", icon: "checkmark") {
                selection.removeAll()
                editMode = .inactive
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func batchButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playlists

struct PlaylistsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showCreate = false
    @State private var showSpotify = false

    var body: some View {
        Group {
            if model.displayPlaylists.isEmpty {
                EmptyStateView(icon: "list.bullet", title: "No playlists yet",
                               message: "Playlists need a music server. Create one here once a server is set up, or import one from Spotify.")
            } else {
                List {
                    ForEach(model.displayPlaylists) { playlist in
                        NavigationLink {
                            PlaylistScreen(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showCreate = true
                    } label: { Label("New Playlist", systemImage: "plus") }
                    Button {
                        showSpotify = true
                    } label: { Label("Import from Spotify", systemImage: "arrow.down.doc") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add playlist")
            }
        }
        .sheet(isPresented: $showCreate) { CreatePlaylistSheet() }
        .sheet(isPresented: $showSpotify) { SpotifyImportSheet() }
        .refreshable { await model.loadLibrary() }
    }
}

struct CreatePlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var serverID: String = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if model.servers.isEmpty {
                    Text("Playlists need a music server. Add one in Settings → Servers first.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Playlist name", text: $name)
                        .font(.body)
                    Picker("Server", selection: $serverID) {
                        ForEach(model.servers) { server in
                            Text(server.name).tag(server.id)
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Button {
                        working = true
                        Task {
                            do {
                                try await model.createPlaylist(name: name, songIDs: [], onServer: serverID)
                                await model.loadLibrary()
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                            working = false
                        }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text("Create Playlist")
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if serverID.isEmpty {
                    serverID = model.defaultServer?.id ?? model.servers.first?.id ?? ""
                }
            }
        }
    }
}

struct SpotifyImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""
    @State private var importing = false
    @State private var resultText: String?
    @State private var unmatched: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Spotify playlist link", text: $link)
                        .font(.body)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("New playlist name", text: $name)
                        .font(.body)
                } header: {
                    Text("Spotify Playlist")
                } footer: {
                    Text("Paste a public Spotify playlist link. Matcha Music finds the same songs on your server and makes a playlist from them. Only the songs your server has can be matched.")
                }
                if model.defaultServer == nil {
                    Text("A music server is needed as the import target. Add one in Settings first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let resultText {
                    Section("Result") {
                        Text(resultText).font(.body)
                        ForEach(unmatched, id: \.self) { item in
                            Text(item).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        importing = true
                        Task {
                            defer { importing = false }
                            guard let target = model.defaultServer,
                                  let backend = model.backend(for: target.id) else { return }
                            do {
                                let result = try await SpotifyImporter.importInto(
                                    backend: backend,
                                    playlistName: name.isEmpty ? "Spotify Playlist" : name,
                                    urlString: link
                                )
                                resultText = "Matched \(result.matched) songs into the new playlist."
                                unmatched = result.unmatched.map { "Not found on your server: \($0)" }
                                await model.loadLibrary()
                            } catch {
                                resultText = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            if importing { ProgressView() }
                            Text("Import Playlist")
                        }
                    }
                    .disabled(link.isEmpty || importing || model.defaultServer == nil)
                }
            }
            .navigationTitle("Import from Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PlaylistScreen: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var songs: [Song] = []
    @State private var synced = false
    @State private var playlistTarget: Song?

    var body: some View {
        List {
            Section {
                PlayAllHeader(songs: songs)
                Toggle(isOn: $synced) {
                    Label("Download & Keep in Sync", systemImage: "arrow.down.circle")
                        .font(.body)
                }
                .onChange(of: synced) { _, on in
                    DownloadManager.shared.setPlaylistSynced(playlist, on)
                    if on {
                        Task {
                            await model.refreshSyncedPlaylists()
                            songs = await model.playlistSongs(playlist)
                        }
                    }
                }
                Text("New songs added to this playlist on the server download automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(songs) { song in
                    SongRow(song: song, queue: songs,
                            isCurrent: model.player.currentSong?.uid == song.uid,
                            onAddToPlaylist: { playlistTarget = $0 })
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: playlist.uid) {
            synced = DownloadManager.shared.isPlaylistSynced(playlist)
            songs = await model.playlistSongs(playlist)
        }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }
}

// MARK: - Genres & decades

struct GenresScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.genres.isEmpty {
                EmptyStateView(icon: "tag", title: "No genres yet",
                               message: "Genres from your servers and library will appear here.")
            } else {
                List {
                    ForEach(model.genres, id: \.self) { genre in
                        NavigationLink {
                            GenreScreen(genre: genre)
                        } label: {
                            Text(genre).font(.body)
                        }
                    }
                }
            }
        }
        .navigationTitle("Genres")
    }
}

struct GenreScreen: View {
    @Environment(AppModel.self) private var model
    let genre: String
    @State private var albums: [Album] = []

    var body: some View {
        Group {
            if albums.isEmpty {
                EmptyStateView(icon: "tag", title: "No albums in \(genre)",
                               message: "No albums in this genre were found on your servers.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink {
                                AlbumScreen(album: album)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(genre)
        .task(id: genre) { albums = await model.albumsByGenre(genre) }
    }
}

struct DecadesScreen: View {
    @Environment(AppModel.self) private var model

    private var groups: [(label: String, albums: [Album])] {
        var byDecade: [Int: [Album]] = [:]
        var unknown: [Album] = []
        for album in model.displayAlbums {
            if let year = album.year {
                byDecade[(year / 10) * 10, default: []].append(album)
            } else {
                unknown.append(album)
            }
        }
        var result = byDecade.keys.sorted(by: >).map { decade in
            (label: "\(decade)s", albums: byDecade[decade] ?? [])
        }
        if !unknown.isEmpty { result.append((label: "Year Unknown", albums: unknown)) }
        return result
    }

    var body: some View {
        List {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.albums) { album in
                        NavigationLink {
                            AlbumScreen(album: album)
                        } label: {
                            AlbumRow(album: album)
                        }
                    }
                }
            }
        }
        .navigationTitle("By Decade")
    }
}

// MARK: - Search

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var searching = false
    @State private var recentSearches: [String] =
        UserDefaults.standard.stringArray(forKey: "matcha.recentSearches") ?? []
    @State private var playlistTarget: Song?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                List {
                    Section {
                        Text("Search finds artists, albums and songs across every server and this iPhone.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    if !recentSearches.isEmpty {
                        Section("Recent Searches") {
                            ForEach(recentSearches, id: \.self) { term in
                                Button(term) { query = term }
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            } else if results.isEmpty && !searching {
                EmptyStateView(icon: "magnifyingglass", title: "No results for \u{201C}\(trimmedQuery)\u{201D}",
                               message: "Check the spelling, or try the artist or album name.")
            } else {
                List {
                    if searching {
                        HStack { ProgressView(); Text("Searching…").font(.body).foregroundStyle(.secondary) }
                    }
                    if !results.artists.isEmpty {
                        Section("Artists") {
                            ForEach(results.artists) { artist in
                                NavigationLink {
                                    ArtistScreen(artist: artist)
                                } label: {
                                    ArtistRow(artist: artist)
                                }
                            }
                        }
                    }
                    if !results.albums.isEmpty {
                        Section("Albums") {
                            ForEach(results.albums) { album in
                                NavigationLink {
                                    AlbumScreen(album: album)
                                } label: {
                                    AlbumRow(album: album)
                                }
                            }
                        }
                    }
                    if !results.songs.isEmpty {
                        Section("Songs") {
                            ForEach(results.songs) { song in
                                SongRow(song: song, queue: results.songs,
                                        isCurrent: model.player.currentSong?.uid == song.uid,
                                        onAddToPlaylist: { playlistTarget = $0 })
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artists, Albums, Songs")
        .onSubmit(of: .search) { saveRecentSearch() }
        .task(id: query) {
            guard !trimmedQuery.isEmpty else {
                results = SearchResults()
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            searching = true
            results = await model.search(query: trimmedQuery)
            searching = false
        }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }

    private func saveRecentSearch() {
        let term = trimmedQuery
        guard !term.isEmpty else { return }
        recentSearches.removeAll { $0.lowercased() == term.lowercased() }
        recentSearches.insert(term, at: 0)
        recentSearches = Array(recentSearches.prefix(10))
        UserDefaults.standard.set(recentSearches, forKey: "matcha.recentSearches")
    }
}

// MARK: - Favourites

struct FavouritesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var playlistTarget: Song?

    var body: some View {
        Group {
            if model.favourites.isEmpty {
                EmptyStateView(icon: "heart", title: "No favourites yet",
                               message: "Tap the heart on any song to add it to your favourites.")
            } else {
                List {
                    Section {
                        PlayAllHeader(songs: model.favourites)
                    }
                    Section {
                        ForEach(model.favourites) { song in
                            SongRow(song: song, queue: model.favourites,
                                    isCurrent: model.player.currentSong?.uid == song.uid,
                                    onAddToPlaylist: { playlistTarget = $0 })
                        }
                    }
                }
            }
        }
        .navigationTitle("Favourites")
        .refreshable { await model.loadLibrary() }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }
}

// MARK: - Downloads

struct DownloadsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemoveAll = false
    @State private var cacheBytes: Int64 = StreamCache.shared.currentBytes()
    @State private var playlistTarget: Song?

    private var downloadedSongs: [Song] {
        DownloadManager.shared.downloaded.values
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var syncedPlaylists: [Playlist] {
        model.playlists.filter { DownloadManager.shared.isPlaylistSynced($0) }
    }

    var body: some View {
        List {
            Section("Storage") {
                LabeledContent("Downloads",
                               value: ByteCountFormatter.string(fromByteCount: DownloadManager.shared.totalBytes(), countStyle: .file))
                LabeledContent("Stream Cache",
                               value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                Button("Clear Stream Cache") {
                    StreamCache.shared.clear()
                    cacheBytes = StreamCache.shared.currentBytes()
                }
                Button("Remove All Downloads", role: .destructive) {
                    confirmRemoveAll = true
                }
                .disabled(downloadedSongs.isEmpty)
            }
            if !syncedPlaylists.isEmpty {
                Section("Synced Playlists") {
                    ForEach(syncedPlaylists) { playlist in
                        NavigationLink {
                            PlaylistScreen(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                }
            }
            Section("Downloaded Songs") {
                if downloadedSongs.isEmpty {
                    Text("No downloads yet. Download songs, albums or playlists to play them with no connection.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloadedSongs) { song in
                        SongRow(song: song, queue: downloadedSongs,
                                isCurrent: model.player.currentSong?.uid == song.uid,
                                onAddToPlaylist: { playlistTarget = $0 })
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    DownloadManager.shared.remove(song: song)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Remove all downloads?",
                            isPresented: $confirmRemoveAll,
                            titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                DownloadManager.shared.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded song is deleted from this iPhone. Your servers are not affected.")
        }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }
}

// MARK: - Stats

struct StatsScreen: View {
    @Environment(AppModel.self) private var model

    private enum Period: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var since: Date {
            switch self {
            case .week: return Date().addingTimeInterval(-7 * 24 * 3600)
            case .month: return Date().addingTimeInterval(-30 * 24 * 3600)
            case .all: return .distantPast
            }
        }
    }

    private enum TopKind: String, CaseIterable, Identifiable {
        case songs, artists, albums
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var period: Period = .all
    @State private var topKind: TopKind = .songs

    private struct TopRow {
        var uid: String?
        var title: String
        var subtitle: String
        var count: Int
        var totalMs: Int
    }

    private var topStats: [TopRow] {
        switch topKind {
        case .songs:
            return PlayHistoryStore.shared.topSongs(limit: 10, since: period.since)
                .map { TopRow(uid: $0.uid, title: $0.title, subtitle: $0.artist, count: $0.count, totalMs: $0.totalMs) }
        case .artists:
            return PlayHistoryStore.shared.topArtists(limit: 10, since: period.since)
                .map { TopRow(uid: nil, title: $0.name, subtitle: "All albums", count: $0.count, totalMs: $0.totalMs) }
        case .albums:
            return PlayHistoryStore.shared.topAlbums(limit: 10, since: period.since)
                .map { TopRow(uid: nil, title: $0.album, subtitle: $0.artist, count: $0.count, totalMs: $0.totalMs) }
        }
    }

    var body: some View {
        let totals = PlayHistoryStore.shared.totalStats(since: period.since)
        let minutes = PlayHistoryStore.shared.minutesPerDay(days: 14)
        let pastYears = PlayHistoryStore.shared.fromThisMonthInPastYears()
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statBlock("Plays", value: "\(totals.plays)")
                    statBlock("Listened", value: formatMs(totals.ms))
                    statBlock("Songs", value: "\(totals.uniqueSongs)")
                    statBlock("Artists", value: "\(totals.uniqueArtists)")
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            Section("Listening — Last 14 Days") {
                Chart(minutes, id: \.day) { point in
                    BarMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Minutes", point.minutes)
                    )
                    .foregroundStyle(model.settings.accent.color)
                }
                .frame(height: 160)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
            }
            Section {
                Picker("Top", selection: $topKind) {
                    ForEach(TopKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if topStats.isEmpty {
                    Text("Nothing played in this period yet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(topStats.enumerated()), id: \.offset) { index, stat in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topTitle(stat))
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(topSubtitle(stat))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(stat.count) plays")
                                .font(.callout.weight(.semibold))
                            Text(formatMs(stat.totalMs))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if topKind == .songs, let uid = stat.uid, let song = model.song(byUID: uid) {
                            model.player.play(songs: [song], startIndex: 0, model: model)
                        }
                    }
                }
            }
            if !pastYears.isEmpty {
                Section("This Month in Past Years") {
                    ForEach(Array(pastYears.enumerated()), id: \.offset) { _, stat in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                Text(stat.artist)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(stat.lastPlayed.formatted(.dateTime.year()))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let song = model.song(byUID: stat.uid) {
                                model.player.play(songs: [song], startIndex: 0, model: model)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Stats")
    }

    private func statBlock(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold))
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }

    private func topTitle(_ stat: TopRow) -> String { stat.title }

    private func topSubtitle(_ stat: TopRow) -> String { stat.subtitle }

    private func formatMs(_ ms: Int) -> String {
        let totalMinutes = ms / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Local files

struct LocalFilesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var importMessage: String?
    @State private var playlistTarget: Song?

    private var fileSongs: [Song] {
        model.songs.filter { $0.serverID == LocalServerID.files }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Text("Import audio files from the Files app and they join your library — playable, searchable and favourite-able, with their artwork and tags read on this iPhone. Files are copied into Matcha Music's own folder, so deleting one here doesn't touch the original.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button {
                    importing = true
                } label: {
                    Label("Import Files", systemImage: "square.and.arrow.down")
                        .font(.body.weight(.semibold))
                }
                .frame(minHeight: 44)
                if let importMessage {
                    Text(importMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Imported Files (\(fileSongs.count))") {
                if fileSongs.isEmpty {
                    Text("No imported files yet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fileSongs) { song in
                        SongRow(song: song, queue: fileSongs,
                                isCurrent: model.player.currentSong?.uid == song.uid,
                                onAddToPlaylist: { playlistTarget = $0 })
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    delete(song)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Local Files")
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .sheet(item: $playlistTarget) { song in
            AddToPlaylistSheet(songs: [song])
        }
    }

    private func delete(_ song: Song) {
        if let url = song.localFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        Task { await model.reloadLocalFiles() }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var copied = 0
            var failed = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try FileManager.default.copyItem(at: url, to: uniqueDestination(for: url))
                    copied += 1
                } catch {
                    failed += 1
                }
            }
            importMessage = failed == 0
                ? "Imported \(copied) file\(copied == 1 ? "" : "s")."
                : "Imported \(copied) file\(copied == 1 ? "" : "s"); \(failed) couldn't be copied."
            Task { await model.reloadLocalFiles() }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func uniqueDestination(for url: URL) -> URL {
        let directory = LocalFilesBackend.directory()
        var candidate = directory.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
