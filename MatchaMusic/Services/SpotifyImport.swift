//  SpotifyImport.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Imports a PUBLIC Spotify playlist: reads the track list off Spotify's
//  public embed page, matches each track against one of the user's own
//  servers, and creates the playlist there. No Spotify account or API key.
import Foundation

struct SpotifyTrack: Hashable {
    var title: String
    var artist: String
}

enum SpotifyImporter {
    /// Accepts open.spotify.com/playlist/<id> links (with or without ?si=),
    /// open.spotify.com/embed/playlist/<id>, spotify:playlist:<id> URIs,
    /// and bare playlist IDs.
    static func playlistID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"/playlist/([A-Za-z0-9]+)"#, #"spotify:playlist:([A-Za-z0-9]+)"#] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.numberOfRanges > 1 {
                return (trimmed as NSString).substring(with: match.range(at: 1))
            }
        }
        if trimmed.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }

    static func fetchTracks(playlistID: String) async throws -> [SpotifyTrack] {
        guard let url = URL(string: "https://open.spotify.com/embed/playlist/\(playlistID)") else {
            throw BackendError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try BackendUtil.checkHTTP(response, context: "Spotify")
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw BackendError.server("That playlist looks empty, or Spotify changed its page")
        }
        let tracks = extractTracks(from: html)
        guard !tracks.isEmpty else {
            throw BackendError.server("That playlist looks empty, or Spotify changed its page")
        }
        return tracks
    }

    /// Matches the playlist's tracks on `backend` and creates a playlist
    /// there with the matches. Returns how many matched and the
    /// "Title - Artist" strings that didn't.
    static func importInto(backend: any MusicBackend, playlistName: String, urlString: String) async throws -> (matched: Int, unmatched: [String]) {
        guard let id = playlistID(from: urlString) else {
            throw BackendError.server("That doesn't look like a Spotify playlist link")
        }
        let tracks = try await fetchTracks(playlistID: id)
        var matchedIDs: [String] = []
        var unmatched: [String] = []
        for track in tracks {
            let results = try? await backend.search(query: "\(track.title) \(track.artist)")
            let songs = results?.songs ?? []
            let pick = songs.first(where: { $0.title.lowercased().contains(track.title.lowercased()) }) ?? songs.first
            if let pick {
                matchedIDs.append(pick.id)
            } else {
                unmatched.append("\(track.title) - \(track.artist)")
            }
        }
        if !matchedIDs.isEmpty {
            try await backend.createPlaylist(name: playlistName, songIDs: matchedIDs)
        }
        return (matchedIDs.count, unmatched)
    }

    // MARK: - Embed-page extraction

    private static func extractTracks(from html: String) -> [SpotifyTrack] {
        // The embed page embeds its data as JSON with \" escapes; normalise
        // those first so the patterns below can use plain quotes.
        let normalised = html.replacingOccurrences(of: "\\\"", with: "\"")
        let patterns = [
            // Primary: track objects serialise as "name":"<title>","artists":[{"name":"<artist>"
            #""name":"((?:[^"\\]|\\.)*)","artists":\[\{"name":"((?:[^"\\]|\\.)*)""#,
            // Track form used by the newer embed payload.
            #""track":\{"uri":"[^"]+","name":"((?:[^"\\]|\\.)*)","artists":\[\{"name":"((?:[^"\\]|\\.)*)""#,
        ]
        var tracks: [SpotifyTrack] = []
        var seen = Set<String>()
        func append(title rawTitle: String, artist rawArtist: String?) {
            let title = clean(rawTitle)
            let artist = clean(rawArtist ?? "")
            guard !title.isEmpty else { return }
            let key = title.lowercased() + "|" + artist.lowercased()
            guard seen.insert(key).inserted else { return }
            tracks.append(SpotifyTrack(title: title, artist: artist))
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalised.startIndex..., in: normalised)
            for match in regex.matches(in: normalised, range: range) {
                guard match.numberOfRanges > 2 else { continue }
                let title = (normalised as NSString).substring(with: match.range(at: 1))
                let artist = (normalised as NSString).substring(with: match.range(at: 2))
                append(title: title, artist: artist)
            }
            if !tracks.isEmpty { break }
        }
        return tracks
    }

    /// Undoes JSON string escapes and HTML entities in a captured name.
    private static func clean(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "\\/", with: "/")
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
        s = s.replacingOccurrences(of: "\\\\", with: "\\")
        s = s.replacingOccurrences(of: "\\n", with: " ")
        s = s.replacingOccurrences(of: "\\t", with: " ")
        // \uXXXX escapes.
        if let regex = try? NSRegularExpression(pattern: #"\\u([0-9a-fA-F]{4})"#) {
            var output = ""
            var cursor = s.startIndex
            for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(match.range, in: s), let g = Range(match.range(at: 1), in: s),
                      let code = UInt32(s[g], radix: 16), let scalar = Unicode.Scalar(code) else { continue }
                output += s[cursor..<r.lowerBound]
                output += String(scalar)
                cursor = r.upperBound
            }
            output += s[cursor...]
            s = output
        }
        // HTML entities.
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#x27;", with: "'")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
