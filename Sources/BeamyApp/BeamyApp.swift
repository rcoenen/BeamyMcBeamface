import SwiftUI
import BeamyKit
import AppKit

// AppDelegate to handle file opening from Finder/CLI
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var viewModel: CastingViewModel?
    nonisolated(unsafe) static var pendingURL: URL?
    @MainActor private static var aboutWindowController: NSWindowController?

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

        // Kill any orphaned FFmpeg processes from previous Beamy sessions
        cleanupOrphanedTranscoders()

        // Set larger app icon for About panel (4x size: 1024x1024)
        if let appIcon = NSImage(named: "AppIcon") {
            appIcon.size = NSSize(width: 1024, height: 1024)
            NSApp.applicationIconImage = appIcon
        }

        hookAboutMenu()

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

    func applicationWillUpdate(_ notification: Notification) {
        if let mainMenu = NSApp.mainMenu {
            // Remove File menu
            if let fileMenuItem = mainMenu.item(withTitle: "File") {
                mainMenu.removeItem(fileMenuItem)
            }

            // Remove Edit menu
            if let editMenuItem = mainMenu.item(withTitle: "Edit") {
                mainMenu.removeItem(editMenuItem)
            }

            // Remove View menu
            if let viewMenuItem = mainMenu.item(withTitle: "View") {
                mainMenu.removeItem(viewMenuItem)
            }

            // Remove Window menu
            if let windowMenuItem = mainMenu.item(withTitle: "Window") {
                mainMenu.removeItem(windowMenuItem)
            }

            // Remove Help menu
            if let helpMenuItem = mainMenu.item(withTitle: "Help") {
                mainMenu.removeItem(helpMenuItem)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("[AppDelegate] applicationWillTerminate")

        // Clean up Chromecast connection and stop receiver to clear screen
        // Called on main thread already, so just call directly
        if let vm = Self.viewModel {
            vm.terminatePlayback()
            log("[AppDelegate] Cleaned up playback and stopped Chromecast receiver")
        }
    }

    /// Redirects the default About menu item to our custom About window.
    private func hookAboutMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenu = mainMenu.items.first?.submenu,
              let aboutItem = appMenu.items.first else { return }
        aboutItem.target = self
        aboutItem.action = #selector(openCustomAbout)
    }

    @objc private func openCustomAbout(_ sender: Any?) {
        Task { @MainActor in
            AppDelegate.showAboutWindow()
        }
    }

    @MainActor
    static func showAboutWindow() {
        // Reuse the window controller if it already exists.
        if let controller = aboutWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let windowSize = NSSize(width: 450, height: 410)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "About Beamy"
        window.isReleasedWhenClosed = false

        // Set size constraints to prevent resizing
        window.minSize = windowSize
        window.maxSize = windowSize
        window.contentMinSize = windowSize
        window.contentMaxSize = windowSize

        window.contentView = NSHostingView(rootView: AboutView())

        let controller = NSWindowController(window: window)
        aboutWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func cleanupOrphanedTranscoders() {
        log("[AppDelegate] Cleaning up orphaned transcoders...")

        // Find and kill FFmpeg processes that were started by Beamy (have beamy-hls in path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "beamy-hls"]

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                log("[AppDelegate] Killed orphaned FFmpeg processes")
            }
        } catch {
            log("[AppDelegate] pkill error: \(error)")
        }

        // Also clean up old temp directories
        let tempDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for item in contents where item.lastPathComponent.hasPrefix("beamy-hls-") {
                try? FileManager.default.removeItem(at: item)
                log("[AppDelegate] Removed old temp dir: \(item.lastPathComponent)")
            }
        }
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
            CommandGroup(replacing: .appInfo) {
                Button("About Beamy") {
                    AppDelegate.showAboutWindow()
                }
            }
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

private struct AboutView: View {
    private var icon: NSImage {
        if let img = NSImage(named: "AppIcon")?.copy() as? NSImage {
            img.size = NSSize(width: 256, height: 256) // icon for About window
            return img
        }
        return NSImage(size: NSSize(width: 256, height: 256))
    }

    private var versionString: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return [short, build].filter { !$0.isEmpty }.joined(separator: " (\(build))")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 256, height: 256)
                .shadow(radius: 8)

            Text("Beamy")
                .font(.system(size: 36, weight: .semibold))

            if !versionString.isEmpty {
                Text(versionString)
                .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text("Fast transcoding and casting for your local videos.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
