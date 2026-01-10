import SwiftUI
import BeamyKit
import AppKit

// AppDelegate to handle file opening from Finder/CLI
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var viewModel: CastingViewModel?
    nonisolated(unsafe) static var pendingURL: URL?
    @MainActor private static var aboutWindowController: NSWindowController?
    private var menusStable = false

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

        // Remove unwanted menus after a short delay to ensure they're ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.removeUnwantedMenus()
        }
    }

    @discardableResult
    private func removeUnwantedMenus() -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }

        let menusToRemove = ["File", "Edit", "View", "Window", "Help"]
        var foundAny = false

        for menuTitle in menusToRemove {
            if let menuItem = mainMenu.item(withTitle: menuTitle) {
                mainMenu.removeItem(menuItem)
                foundAny = true
            }
        }

        // Return true if stable (no menus found)
        return !foundAny
    }

    func applicationWillUpdate(_ notification: Notification) {
        // Stop checking once menus are stable (no more recreations)
        guard !menusStable else { return }

        if removeUnwantedMenus() {
            menusStable = true
            log("[AppDelegate] Menus now stable")
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

        let windowSize = NSSize(width: 520, height: 500)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "About Beamy McBeamface"
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
                Button("About Beamy McBeamface") {
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

        // Settings window (hidden for now)
        // Settings {
        //     SettingsView()
        //         .environmentObject(viewModel)
        // }
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
        VStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 180, height: 180)
                .shadow(radius: 8)

            Text("Beamy McBeamface")
                .font(.system(size: 28, weight: .semibold))

            Text("Beaming is Streaming!")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .italic()

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)

            Text("The free, open-source video beamer for Mac")
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 460)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                Text("Beam any video to your TV — for free.")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Drag, drop & watch on Chromecast", systemImage: "tv")
                    Label("Plays MKV, AVI, MP4, MOV & more", systemImage: "film")
                    Label("Transcodes on-the-fly via FFmpeg", systemImage: "gearshape.2")
                    Label("Apple TV support coming soon", systemImage: "appletv")
                }
                .font(.callout)
                .foregroundColor(.secondary)

                Divider()
                    .frame(width: 460)
                    .padding(.vertical, 4)

                HStack(alignment: .top, spacing: 4) {
                    Text("To beam")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("(Euro-English) 🇪🇺")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("verb — to project something using a beamer (projector).\n(That's \"streaming\" for our non-Euro-English friends 😉)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }

            Spacer()

            Link("github.com/rcoenen/BeamyMcBeamface", destination: URL(string: "https://github.com/rcoenen/BeamyMcBeamface")!)
                .font(.caption)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
