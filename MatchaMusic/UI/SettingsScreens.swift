//  SettingsScreens.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Settings + Add Server (Subsonic / Jellyfin forms and the Plex PIN
//  flow). House style: pickers are whole-row tappable with a checkmark
//  on the active choice, appearance applies instantly, and every secret
//  goes to the Keychain — never to UserDefaults or a file.
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var listenBrainzToken: String =
        KeychainStore.get(KeychainStore.listenBrainzTokenAccount) ?? ""
    @State private var listenBrainzSaved = false
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var cacheBytes: Int64 = StreamCache.shared.currentBytes()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            // MARK: Servers
            Section {
                ForEach(model.servers) { server in
                    Button {
                        Haptics.tap(settings)
                        model.setDefaultServer(server)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: server.type.symbol)
                                .foregroundStyle(settings.accent.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(server.type.displayName) · \(server.username)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if server.isDefault {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(settings.accent.color)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            model.removeServer(server)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .foregroundStyle(settings.accent.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On This iPhone")
                            .font(.body.weight(.semibold))
                        Text("Music library on this device")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    LocalFilesScreen()
                } label: {
                    Label("Local Files", systemImage: "folder.fill")
                        .font(.body)
                }
                NavigationLink {
                    AddServerScreen()
                } label: {
                    Label("Add Server", systemImage: "plus.circle.fill")
                        .font(.body)
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Tap a server to make it the default — the Albums, Artists, Songs and Playlists tabs show the default server, while Home, Search and Favourites include everything. Passwords are stored only in the Keychain.")
            }

            // MARK: Appearance
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(AccentChoice.allCases) { choice in
                    Button {
                        Haptics.tap(settings)
                        settings.accent = choice
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 26, height: 26)
                            Text(choice.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if settings.accent == choice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(settings.accent.color)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(TextSizeChoice.allCases) { choice in
                    Button {
                        Haptics.tap(settings)
                        settings.textSize = choice
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size")
                                .foregroundStyle(.secondary)
                            Text("Text Size — \(choice.label)")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if settings.textSize == choice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(settings.accent.color)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Appearance, accent and text size apply instantly, everywhere in the app.")
            }

            // MARK: Playback
            Section {
                Picker("Streaming Quality", selection: $settings.streamingQuality) {
                    ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Record Plays on Server", isOn: $settings.recordPlaysOnServer)
                LabeledContent("Stream Cache",
                               value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                Button("Clear Stream Cache") {
                    StreamCache.shared.clear()
                    StreamCache.shared.prune(maxMB: settings.streamCacheMaxMB)
                    cacheBytes = StreamCache.shared.currentBytes()
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Streaming quality asks your server to transcode; Original always plays the file as stored. Downloads are always saved in original quality.")
            }

            // MARK: Music
            Section {
                Toggle("Lyrics", isOn: $settings.lyricsEnabled)
                Toggle("Artwork Lookups", isOn: $settings.artworkFallbackEnabled)
                Toggle("Auto-Download Favourites", isOn: $settings.autoDownloadFavourites)
                Toggle("Offline Mode", isOn: $settings.offlineMode)
            } header: {
                Text("Music")
            } footer: {
                Text("Artwork Lookups fetch missing covers from Deezer, iTunes and Cover Art Archive — only the artist and album names are sent. Offline Mode shows only downloaded songs and music on this iPhone.")
            }

            // MARK: ListenBrainz
            Section {
                Toggle("Scrobble to ListenBrainz", isOn: $settings.listenBrainzEnabled)
                SecureField("ListenBrainz user token", text: $listenBrainzToken)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    KeychainStore.set(listenBrainzToken.trimmingCharacters(in: .whitespaces),
                                      account: KeychainStore.listenBrainzTokenAccount)
                    ListenBrainzScrobbler.shared.reloadToken()
                    listenBrainzSaved = true
                } label: {
                    HStack {
                        Text("Save Token")
                        if listenBrainzSaved {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            } header: {
                Text("ListenBrainz")
            } footer: {
                Text("Optional. Create a free account at listenbrainz.org, copy your user token from its settings page, and finished songs are submitted there. The token is stored only in the Keychain. Nothing is sent while this is off.")
            }

            // MARK: Spotify
            Section {
                NavigationLink {
                    PlaylistsScreen()
                } label: {
                    Label("Import a Spotify Playlist", systemImage: "arrow.down.doc")
                        .font(.body)
                }
            } header: {
                Text("Spotify")
            } footer: {
                Text("Open Playlists, tap +, and choose Import from Spotify.")
            }

            // MARK: Data
            Section {
                LabeledContent("Downloads Storage",
                               value: ByteCountFormatter.string(fromByteCount: DownloadManager.shared.totalBytes(), countStyle: .file))
                ShareLink(item: model.exportSettings()) {
                    Label("Export Settings", systemImage: "square.and.arrow.up")
                        .font(.body)
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import Settings", systemImage: "square.and.arrow.down")
                        .font(.body)
                }
                .frame(minHeight: 44)
                if let importMessage {
                    Text(importMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Exports contain your server addresses, usernames and preferences — never passwords or tokens. Imported servers ask for their password again before they can connect.")
            }

            // MARK: About
            Section {
                LabeledContent("App", value: "Matcha Music")
                LabeledContent("Version", value: "1.0.0")
                NavigationLink {
                    DataSourcesView()
                } label: {
                    Label("Data Sources & Credits", systemImage: "books.vertical")
                        .font(.body)
                }
                Text("Copyright (c) 2026 c12n Apps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            } footer: {
                Text("Matcha Music has no accounts, no tracking, no ads and no analytics. Your music, passwords and listening history stay on this iPhone and on the servers you add — the only other traffic is the disclosed lyrics, artwork, artist-info and (optional) ListenBrainz lookups described in Data Sources.")
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                if let url = urls.first {
                    try model.importSettings(url: url)
                    importMessage = "Settings imported. Imported servers need their password re-entered (edit by removing and re-adding) before they connect."
                }
            } catch {
                importMessage = "Couldn't import that file: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Data sources

struct DataSourcesView: View {
    var body: some View {
        List {
            Section {
                Text("The iPhone app is built only on Apple's frameworks (SwiftUI, AVFoundation, MediaPlayer, SQLite). These free services are used for lookups; each entry says exactly what is sent.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            source("LRCLIB — lyrics",
                   detail: "Sends the artist, track title, album and duration to lrclib.net to fetch lyrics. Lyrics data is CC0.")
            source("Wikipedia — artist biographies",
                   detail: "Sends the artist name to en.wikipedia.org to fetch the summary biography. Content is CC BY-SA.")
            source("Deezer — artist photos & similar artists",
                   detail: "Sends the artist or album name to api.deezer.com. Content is CC BY-SA where attributed.")
            source("iTunes Search — missing album artwork",
                   detail: "Sends the artist and album names to itunes.apple.com and uses the returned artwork URL.")
            source("MusicBrainz / Cover Art Archive — missing album artwork",
                   detail: "Sends the artist and album names to musicbrainz.org to find a release group, then loads its front cover from coverartarchive.org. Metadata is CC0 / public domain where marked.")
            source("ListenBrainz — optional scrobbling",
                   detail: "Only when you turn it on and save a token: finished songs (artist, title, album, time) are submitted to api.listenbrainz.org with your token.")
            source("Spotify — playlist import",
                   detail: "Only when you paste a link: the public playlist page is read from open.spotify.com and its track names are matched against your own server. Nothing is sent to Spotify.")
        }
        .navigationTitle("Data Sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func source(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add server

struct AddServerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var type: ServerType = .subsonic
    @State private var name = ""
    @State private var serverURLText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?

    // Plex PIN flow state
    @State private var plexPINID: Int?
    @State private var plexCode: String?
    @State private var plexToken: String?
    @State private var plexResources: [PlexResource] = []
    @State private var plexStatus: String?

    var body: some View {
        Form {
            Section {
                Picker("Server Type", selection: $type) {
                    ForEach(ServerType.allCases) { serverType in
                        Text(serverType.displayName).tag(serverType)
                    }
                }
                .pickerStyle(.segmented)
            }

            if type == .plex {
                plexSection
            } else {
                formSection
            }

            Section {
                Text("Tip: with Tailscale, use your server's Tailscale address (100.x.y.z or a MagicDNS name) so it works away from home too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Subsonic / Jellyfin form

    private var formSection: some View {
        Section {
            TextField("Name (optional)", text: $name)
                .font(.body)
            TextField(type == .jellyfin ? "Server address — e.g. http://192.168.1.10:8096" : "Server address — e.g. http://192.168.1.10:4533",
                      text: $serverURLText)
                .font(.body)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .font(.body)
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button {
                working = true
                errorText = nil
                Task {
                    defer { working = false }
                    do {
                        let config = ServerConfig.make(
                            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? type.displayName : name,
                            type: type,
                            baseURL: normalizedURL(serverURLText),
                            username: username.trimmingCharacters(in: .whitespaces),
                            isDefault: model.servers.isEmpty
                        )
                        try await model.testServer(config: config, secret: password)
                        model.addServer(config: config, secret: password)
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    if working { ProgressView() }
                    Text("Test & Save Server")
                        .font(.body.weight(.semibold))
                }
            }
            .disabled(serverURLText.isEmpty || username.isEmpty || password.isEmpty || working)
            .frame(minHeight: 44)
        } header: {
            Text(type.displayName)
        } footer: {
            Text("The connection is tested before saving. Your password is stored only in the Keychain — if you cancel, remove the server from Settings to clear it.")
        }
    }

    // MARK: Plex PIN flow

    private var plexSection: some View {
        Section {
            if plexToken == nil {
                Button {
                    working = true
                    plexStatus = nil
                    Task {
                        defer { working = false }
                        do {
                            let pin = try await PlexAuth.createPIN()
                            plexPINID = pin.id
                            plexCode = pin.code
                            openURL(PlexAuth.authURL(code: pin.code))
                            plexStatus = "Approve Matcha Music in your browser, then come back and tap I've Approved."
                        } catch {
                            plexStatus = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        if working { ProgressView() }
                        Text("Sign in with Plex")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(minHeight: 44)
                if plexCode != nil {
                    Button {
                        working = true
                        Task {
                            defer { working = false }
                            guard let plexPINID else { return }
                            do {
                                if let token = try await PlexAuth.pollPIN(id: plexPINID) {
                                    KeychainStore.set(token, account: KeychainStore.plexAuthTokenAccount)
                                    plexToken = token
                                    plexResources = try await PlexAuth.resources(authToken: token)
                                    plexStatus = plexResources.isEmpty
                                        ? "No Plex servers were found on this account."
                                        : "Pick your Plex server:"
                                } else {
                                    plexStatus = "Not approved yet — finish approving in your browser, then tap again."
                                }
                            } catch {
                                plexStatus = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("I've Approved — Continue")
                            .font(.body.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                }
            }
            if let plexStatus {
                Text(plexStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(plexResources.filter { $0.provides.contains("server") }, id: \.name) { resource in
                Button {
                    guard let uri = bestConnectionURI(for: resource) else { return }
                    let config = ServerConfig.make(
                        name: resource.name,
                        type: .plex,
                        baseURL: uri,
                        username: resource.name,
                        isDefault: model.servers.isEmpty
                    )
                    model.addServer(config: config, secret: resource.accessToken)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(resource.product)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Plex")
        } footer: {
            Text("Plex sign-in happens on plex.tv in your browser — Matcha Music never sees your Plex password. The access token is stored only in the Keychain.")
        }
    }

    /// Prefer a plex.direct connection (works away from home), then a
    /// local connection, then whatever the server listed first.
    private func bestConnectionURI(for resource: PlexResource) -> String? {
        if let direct = resource.connections.first(where: { $0.uri.contains("plex.direct") }) {
            return direct.uri
        }
        if let local = resource.connections.first(where: { $0.local }) {
            return local.uri
        }
        return resource.connections.first?.uri
    }

    private func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "http://" + trimmed
    }
}
