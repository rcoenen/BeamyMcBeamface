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
        .defaultSize(width: 760, height: 480)
        .commands {
            // Playback commands
            CommandMenu("Playback") {
                Button("Play/Pause") {
                    viewModel.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Divider()

                Button("Skip Forward 10s") {
                    viewModel.skipForward()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Skip Backward 10s") {
                    viewModel.skipBackward()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Divider()

                Button("Stop") {
                    viewModel.stopPlayback()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }

            // Output commands
            CommandMenu("Output") {
                Button("Switch to mpv") {
                    viewModel.switchOutput(to: .mpv)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Switch to Chromecast") {
                    viewModel.switchOutput(to: .chromecast)
                }
                .keyboardShortcut("2", modifiers: [.command])
            }

            // Remove standard menus we don't need
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }
            CommandGroup(replacing: .windowSize) { }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) { }
        }

        // Menu bar extra
        MenuBarExtra("Beamy", systemImage: "tv") {
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
