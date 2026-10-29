//  SharedSnapshot.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  A tiny Codable snapshot of what the app is playing, written by the app
//  into the shared App Group defaults and read by the widget. Compiled
//  into BOTH the app target and the widget target — keep it dependency
//  free (Foundation only).
import Foundation

struct SharedSnapshot: Codable {
    var currentTitle: String
    var currentArtist: String
    var isPlaying: Bool
    /// Titles of favourite songs (up to 5), most relevant first.
    var favourites: [String]
    /// Titles of recently played songs (up to 5), most recent first.
    var recent: [String]

    static let suiteName = "group.com.c12n.matchamusic"
    static let defaultsKey = "snapshot"

    static func write(_ snapshot: SharedSnapshot) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func read() -> SharedSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SharedSnapshot.self, from: data)
    }
}
