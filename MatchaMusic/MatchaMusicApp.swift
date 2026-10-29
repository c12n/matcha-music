//  MatchaMusicApp.swift — Matcha Music (c12n rebuild)
//  Copyright (c) 2026 c12n Apps
import SwiftUI

@main
struct MatchaMusicApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootContainer()
        }
    }
}

/// Owns the app-wide AppModel (created on the main actor, as SwiftUI
/// view state is) and injects it — and its settings — into the
/// environment for every screen.
private struct AppRootContainer: View {
    @State private var model = AppModel()

    var body: some View {
        RootView()
            .environment(model)
            .environment(model.settings)
    }
}
