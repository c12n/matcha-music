//  AppSettings.swift — house style from Viu Live TV + AlRashid Prayer:
//  System/Light/Dark segmented appearance, accent colours, and an
//  AlRashid-style Standard / Large / Extra Large text-size choice.
import SwiftUI
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case matcha, blue, purple, pink, orange, teal, red
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .matcha: return Color(red: 0.36, green: 0.55, blue: 0.28)
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .teal: return .teal
        case .red: return .red
        }
    }
}

enum TextSizeChoice: String, CaseIterable, Identifiable {
    case standard, large, extraLarge
    var id: String { rawValue }
    var label: String {
        switch self { case .standard: return "Standard"; case .large: return "Large"; case .extraLarge: return "Extra Large" }
    }
    var dynamicTypeSize: DynamicTypeSize {
        switch self { case .standard: return .large; case .large: return .xxLarge; case .extraLarge: return .accessibility1 }
    }
}

enum StreamingQuality: String, CaseIterable, Identifiable {
    case original, high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self { case .original: return "Original"; case .high: return "High (320 kbps)"; case .medium: return "Medium (192 kbps)"; case .low: return "Low (128 kbps)" }
    }
    /// Subsonic maxBitRate / Jellyfin MaxStreamingBitrate value; nil = original.
    var maxBitRateKbps: Int? {
        switch self { case .original: return nil; case .high: return 320; case .medium: return 192; case .low: return 128 }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case az, newest, year, mostPlayed
    var id: String { rawValue }
    var label: String {
        switch self { case .az: return "A–Z"; case .newest: return "Newest"; case .year: return "Year"; case .mostPlayed: return "Most Played" }
    }
}

@Observable
final class AppSettings {
    private enum K {
        static let appearance = "matcha_appearance_mode"
        static let accent = "matcha_accent"
        static let textSize = "matcha_text_size"
        static let haptics = "matcha_haptics"
        static let lyrics = "matcha_lyrics_enabled"
        static let artworkFallback = "matcha_artwork_fallback"
        static let quality = "matcha_streaming_quality"
        static let autoDownloadFavourites = "matcha_autodownload_favourites"
        static let offlineMode = "matcha_offline_mode"
        static let listenBrainz = "matcha_listenbrainz_enabled"
        static let recordPlaysOnServer = "matcha_record_plays_on_server"
        static let albumSort = "matcha_album_sort"
        static let songSort = "matcha_song_sort"
        static let cacheMaxMB = "matcha_stream_cache_max_mb"
    }
    private let d = UserDefaults.standard
    var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: K.appearance) } }
    var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: K.accent) } }
    var textSize: TextSizeChoice { didSet { d.set(textSize.rawValue, forKey: K.textSize) } }
    var hapticsEnabled: Bool { didSet { d.set(hapticsEnabled, forKey: K.haptics) } }
    var lyricsEnabled: Bool { didSet { d.set(lyricsEnabled, forKey: K.lyrics) } }
    var artworkFallbackEnabled: Bool { didSet { d.set(artworkFallbackEnabled, forKey: K.artworkFallback) } }
    var streamingQuality: StreamingQuality { didSet { d.set(streamingQuality.rawValue, forKey: K.quality) } }
    var autoDownloadFavourites: Bool { didSet { d.set(autoDownloadFavourites, forKey: K.autoDownloadFavourites) } }
    var offlineMode: Bool { didSet { d.set(offlineMode, forKey: K.offlineMode) } }
    var listenBrainzEnabled: Bool { didSet { d.set(listenBrainzEnabled, forKey: K.listenBrainz) } }
    var recordPlaysOnServer: Bool { didSet { d.set(recordPlaysOnServer, forKey: K.recordPlaysOnServer) } }
    var albumSort: LibrarySort { didSet { d.set(albumSort.rawValue, forKey: K.albumSort) } }
    var songSort: LibrarySort { didSet { d.set(songSort.rawValue, forKey: K.songSort) } }
    var streamCacheMaxMB: Int { didSet { d.set(streamCacheMaxMB, forKey: K.cacheMaxMB) } }
    init() {
        let d = UserDefaults.standard
        appearance = AppearanceMode(rawValue: d.string(forKey: K.appearance) ?? "") ?? .system
        accent = AccentChoice(rawValue: d.string(forKey: K.accent) ?? "") ?? .matcha
        textSize = TextSizeChoice(rawValue: d.string(forKey: K.textSize) ?? "") ?? .standard
        hapticsEnabled = d.object(forKey: K.haptics) as? Bool ?? true
        lyricsEnabled = d.object(forKey: K.lyrics) as? Bool ?? true
        artworkFallbackEnabled = d.object(forKey: K.artworkFallback) as? Bool ?? true
        streamingQuality = StreamingQuality(rawValue: d.string(forKey: K.quality) ?? "") ?? .original
        autoDownloadFavourites = d.bool(forKey: K.autoDownloadFavourites)
        offlineMode = d.bool(forKey: K.offlineMode)
        listenBrainzEnabled = d.bool(forKey: K.listenBrainz)
        recordPlaysOnServer = d.object(forKey: K.recordPlaysOnServer) as? Bool ?? true
        albumSort = LibrarySort(rawValue: d.string(forKey: K.albumSort) ?? "") ?? .az
        songSort = LibrarySort(rawValue: d.string(forKey: K.songSort) ?? "") ?? .az
        streamCacheMaxMB = d.object(forKey: K.cacheMaxMB) as? Int ?? 500
    }
}

enum Haptics {
    static func tap(_ settings: AppSettings) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func strong(_ settings: AppSettings) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
