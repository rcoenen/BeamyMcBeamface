import SwiftUI
import BeamyKit

// AppDelegate to handle file opening from Finder/CLI
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var viewModel: CastingViewModel?
    nonisolated(unsafe) static var pendingURL: URL?

    private func log(_ message: String) {
        let data = "\(message)\n".data(using: .utf8)!
        if FileManager.default.fileExists(atPath: "/tmp/beamy-delegate.log") {
            if let handle = FileHandle(forWritingAtPath: "/tmp/beamy-delegate.log") {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: "/tmp/beamy-delegate.log", contents: data)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        log("[AppDelegate] willFinishLaunching")
        log("[AppDelegate] args: \(CommandLine.arguments)")

        // Check for file arguments (skip first which is app path)
        for arg in CommandLine.arguments.dropFirst() {
            if FileManager.default.fileExists(atPath: arg) {
                log("[AppDelegate] found file arg in willFinish: \(arg)")
                let url = URL(fileURLWithPath: arg)
                Self.pendingURL = url
            }
        }

        // Check for BEAMY_FILE environment variable (for debugging)
        if let filePath = ProcessInfo.processInfo.environment["BEAMY_FILE"] {
            log("[AppDelegate] found BEAMY_FILE env: \(filePath)")
            if FileManager.default.fileExists(atPath: filePath) {
                Self.pendingURL = URL(fileURLWithPath: filePath)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("[AppDelegate] didFinishLaunching")
        log("[AppDelegate] args: \(ProcessInfo.processInfo.arguments)")

        // Check for file arguments (skip first which is app path)
        let args = ProcessInfo.processInfo.arguments
        for arg in args.dropFirst() {
            if FileManager.default.fileExists(atPath: arg) {
                log("[AppDelegate] found file arg: \(arg)")
                let url = URL(fileURLWithPath: arg)
                Self.pendingURL = url
            }
        }

        // Activate the app and bring to front
        NSApp.activate(ignoringOtherApps: true)
        log("[AppDelegate] activated app")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log("[AppDelegate] open urls: \(urls)")
        guard let url = urls.first else { return }

        if let vm = Self.viewModel {
            log("[AppDelegate] viewModel available, calling handleFileDrop")
            DispatchQueue.main.async {
                vm.handleFileDrop(url: url)
            }
        } else {
            log("[AppDelegate] viewModel NOT available, storing pendingURL")
            Self.pendingURL = url
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        log("[AppDelegate] openFile: \(filename)")
        let url = URL(fileURLWithPath: filename)

        if let vm = Self.viewModel {
            log("[AppDelegate] viewModel available, calling handleFileDrop")
            DispatchQueue.main.async {
                vm.handleFileDrop(url: url)
            }
        } else {
            log("[AppDelegate] viewModel NOT available, storing pendingURL")
            Self.pendingURL = url
        }
        return true
    }

    @MainActor static func processPendingURL() {
        // Debug log via file
        let logData = "[processPendingURL] called, pendingURL=\(String(describing: pendingURL)), viewModel=\(viewModel != nil)\n".data(using: .utf8)!
        if let handle = FileHandle(forWritingAtPath: "/tmp/beamy-delegate.log") {
            handle.seekToEndOfFile()
            handle.write(logData)
            handle.closeFile()
        }

        guard let url = pendingURL, let vm = viewModel else { return }
        pendingURL = nil
        vm.handleFileDrop(url: url)
    }
}

@main
struct BeamyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = CastingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    AppDelegate.viewModel = viewModel
                    AppDelegate.processPendingURL()
                }
        }
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
