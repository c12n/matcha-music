//  Equalizer.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
//
//  Honest scope: AVPlayer — which streams from the servers — has no public
//  EQ hook on iOS, so there is no way to equalise a live stream with public
//  APIs. The EQ below therefore runs through an AVAudioEngine chain
//  (player node -> AVAudioUnitEQ -> output) that serves DOWNLOADED and
//  other LOCAL files, and the Now Playing screen says exactly that.
//  Settings + presets are shared so the UI behaves the same everywhere.
import Foundation
import AVFoundation
import Observation

struct EQPreset: Identifiable, Equatable {
    var name: String
    var gains: [Float]        // 6 bands, dB, -24...+24
    var id: String { name }

    static let bandFrequencies: [Float] = [60, 230, 910, 3600, 8000, 14000]
    /// Alias used by the UI.
    static var presets: [EQPreset] { all }
    static let customName = "Custom"

    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost", gains: [6, 4, 2, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 2, 4, 6]),
        EQPreset(name: "Vocal", gains: [-2, 0, 3, 4, 3, 0]),
        EQPreset(name: "Rock", gains: [5, 3, -1, 2, 4, 5]),
        EQPreset(name: "Electronic", gains: [6, 4, 0, 2, 4, 6]),
        EQPreset(name: "Acoustic", gains: [3, 2, 1, 2, 3, 4]),
    ]
}

@Observable
final class EqualizerSettings {
    static let shared = EqualizerSettings()

    private enum K {
        static let enabled = "matcha.eq.enabled"
        static let preset = "matcha.eq.preset"
        static let gains = "matcha.eq.gains"
    }
    private let d = UserDefaults.standard

    var enabled: Bool { didSet { d.set(enabled, forKey: K.enabled) } }
    var presetName: String { didSet { d.set(presetName, forKey: K.preset) } }
    var customGains: [Float] {
        didSet {
            if let data = try? JSONEncoder().encode(customGains) {
                d.set(data, forKey: K.gains)
            }
        }
    }

    var currentGains: [Float] {
        get {
            if presetName == EQPreset.customName { return customGains }
            return EQPreset.all.first(where: { $0.name == presetName })?.gains
                ?? EQPreset.all[0].gains
        }
        set { applyCustom(gains: newValue) }
    }

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: K.enabled)
        presetName = d.string(forKey: K.preset) ?? "Flat"
        if let data = d.data(forKey: K.gains),
           let gains = try? JSONDecoder().decode([Float].self, from: data), gains.count == 6 {
            customGains = gains
        } else {
            customGains = [0, 0, 0, 0, 0, 0]
        }
    }

    func apply(preset: EQPreset) {
        presetName = preset.name
        if preset.name == EQPreset.customName {
            customGains = preset.gains
        }
    }

    func applyCustom(gains: [Float]) {
        guard gains.count == 6 else { return }
        customGains = gains
        presetName = EQPreset.customName
    }
}

/// Minimal AVAudioEngine player for local files, with a 6-band EQ.
/// Not a replacement for the streaming PlayerEngine — see the header note.
final class LocalEQPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq: AVAudioUnitEQ
    private var file: AVAudioFile?
    private(set) var isPlaying = false
    private(set) var currentURL: URL?

    init() {
        eq = AVAudioUnitEQ(numberOfBands: EQPreset.bandFrequencies.count)
        for (index, band) in eq.bands.enumerated() {
            band.frequency = EQPreset.bandFrequencies[index]
            band.bandwidth = 0.7
            band.filterType = index == 0 ? .lowShelf : (index == eq.bands.count - 1 ? .highShelf : .parametric)
            band.bypass = false
            band.gain = 0
        }
        engine.attach(playerNode)
        engine.attach(eq)
    }

    func load(url: URL, gains: [Float], enabled: Bool) {
        stop()
        do {
            let audioFile = try AVAudioFile(forReading: url)
            file = audioFile
            currentURL = url
            let format = audioFile.processingFormat
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(eq)
            engine.connect(playerNode, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            applyGains(gains, enabled: enabled)
            playerNode.scheduleFile(audioFile, at: nil)
            try engine.start()
        } catch {
            file = nil
            currentURL = nil
        }
    }

    func applyGains(_ gains: [Float], enabled: Bool) {
        eq.bypass = !enabled
        for (index, band) in eq.bands.enumerated() {
            band.gain = index < gains.count ? max(-24, min(24, gains[index])) : 0
        }
    }

    func play() {
        guard file != nil else { return }
        if !engine.isRunning { try? engine.start() }
        playerNode.play()
        isPlaying = true
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        isPlaying = false
    }
}
