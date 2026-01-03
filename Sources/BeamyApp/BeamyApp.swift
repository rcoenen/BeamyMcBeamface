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
        .commands {
            // Remove standard menus
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }
            CommandGroup(replacing: .windowSize) { }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) { }
        }

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
