import SwiftUI
import BeamyKit

@main
struct BeamyApp: App {
    @StateObject private var viewModel = CastingViewModel()

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 400)

        // Menu bar extra
        MenuBarExtra("Beamy McBeamface", systemImage: "tv") {
            MenuBarView()
                .environmentObject(viewModel)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}
