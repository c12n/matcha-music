//  Shortcuts.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Siri / Shortcuts support. Each intent only records a pending command
//  in the App Group defaults and opens the app; AppModel consumes the
//  command when the app comes to the foreground and starts playback.
//  (Honest scope: playback begins in the app, not in the background.)
import AppIntents
import Foundation

private enum PendingCommand {
    static func store(_ command: String) {
        UserDefaults(suiteName: SharedSnapshot.suiteName)?.set(command, forKey: "pendingCommand")
    }
}

struct PlayFavouritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Favourites"
    static var description = IntentDescription("Opens Matcha Music and plays your favourite songs.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingCommand.store("favourites")
        return .result()
    }
}

struct ShuffleAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle All"
    static var description = IntentDescription("Opens Matcha Music and shuffles your whole library.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingCommand.store("shuffle")
        return .result()
    }
}

struct PlayRecentlyPlayedIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Recently Played"
    static var description = IntentDescription("Opens Matcha Music and plays what you listened to most recently.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingCommand.store("recent")
        return .result()
    }
}

struct MatchaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayFavouritesIntent(),
            phrases: [
                "Play my favourites in \(.applicationName)",
                "Play favourites with \(.applicationName)"
            ],
            shortTitle: "Play Favourites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShuffleAllIntent(),
            phrases: [
                "Shuffle my music in \(.applicationName)",
                "Shuffle all in \(.applicationName)"
            ],
            shortTitle: "Shuffle All",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayRecentlyPlayedIntent(),
            phrases: [
                "Play recently played in \(.applicationName)",
                "Play my recent songs with \(.applicationName)"
            ],
            shortTitle: "Play Recently Played",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
