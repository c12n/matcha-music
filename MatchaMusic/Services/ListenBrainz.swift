//  ListenBrainz.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Optional ListenBrainz scrobbling (off by default, Settings key
//  "matcha_listenbrainz_enabled"). The user's own token lives in the
//  Keychain. Every failure is swallowed — scrobbling must never disturb
//  playback.
import Foundation

final class ListenBrainzScrobbler {
    static let shared = ListenBrainzScrobbler()

    private static let enabledKey = "matcha_listenbrainz_enabled"
    private var token: String?

    var isConfigured: Bool {
        if let token, !token.isEmpty { return true }
        return false
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    init() {
        token = KeychainStore.get(KeychainStore.listenBrainzTokenAccount)
    }

    /// Re-reads the token after the user edits it in Settings.
    func reloadToken() {
        token = KeychainStore.get(KeychainStore.listenBrainzTokenAccount)
    }

    func playingNow(song: Song) async {
        await submit(song: song, listenType: "playing_now", listenedAt: nil)
    }

    func scrobble(song: Song, listenedAt: Date) async {
        await submit(song: song, listenType: "single", listenedAt: listenedAt)
    }

    private func submit(song: Song, listenType: String, listenedAt: Date?) async {
        guard isEnabled else { return }
        if token == nil { reloadToken() }
        guard let token, !token.isEmpty else { return }
        guard let url = URL(string: "https://api.listenbrainz.org/1/submit-listens") else { return }

        var trackMetadata: [String: Any] = [
            "artist_name": song.artist,
            "track_name": song.title,
            "additional_info": [
                "media_player": "Matcha Music",
                "duration": song.duration,
                "source": song.serverID,
            ],
        ]
        if !song.album.isEmpty { trackMetadata["release_name"] = song.album }

        var entry: [String: Any] = ["track_metadata": trackMetadata]
        if listenType == "single", let listenedAt {
            entry["listened_at"] = Int(listenedAt.timeIntervalSince1970)
        }
        let body: [String: Any] = [
            "listen_type": listenType,
            "payload": [entry],
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(BackendUtil.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = httpBody
        _ = try? await URLSession.shared.data(for: request)
    }
}
