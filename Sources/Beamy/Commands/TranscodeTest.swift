import ArgumentParser
import BeamyKit
import Foundation
import Rainbow

struct TranscodeTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcode-test",
        abstract: "Test transcoder with seek/pause/resume - validates full architecture"
    )

    @Argument(help: "Input video file path")
    var inputFile: String

    @Option(name: .shortAndLong, help: "Port for HTTP server")
    var port: Int = 8080

    @Flag(name: .shortAndLong, help: "Run automated test sequence")
    var auto: Bool = false

    @Flag(help: "Enable TUI mode (mpv-style interface)")
    var tui: Bool = false

    @Flag(help: "Use mpv with IPC instead of ffplay (more accurate position tracking)")
    var mpv: Bool = false

    @Option(name: .long, help: "Chromecast device name or IP to control via TUI")
    var chromecast: String?

    @Flag(help: "Use TermKit-based UI instead of ANSI TUI")
    var termkit: Bool = false

    func run() throws {
        // Clear old logs
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-tui.log")
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-transcoder-debug.log")

        let inputURL = URL(fileURLWithPath: inputFile)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: inputFile) else {
            throw ValidationError("File not found: \(inputFile)")
        }

        print("=== TRANSCODE TEST ===")
        print("Input: \(inputURL.lastPathComponent)")
        print("Port: \(port)")
        print("")

        // Get media info
        print("Getting media info...")
        let mediaInfo = try FFmpeg.getMediaInfo(file: inputURL)
        print("Duration: \(formatTime(mediaInfo.duration))")
        print("")

        // Start transcoder server
        print("Starting transcoder server...")
        let server = try TranscodeServer(input: inputURL, port: port, mediaInfo: mediaInfo)

        print("")
        print("========================================")
        print("Stream ready at: \(server.url)")
        print("")
        print("In another terminal, run:")
        print("  ffplay -i \(server.url)")
        print("========================================")
        print("")

        if let chromecast = chromecast {
            try runChromecastMode(server: server, duration: mediaInfo.duration, deviceNameOrIP: chromecast, title: inputURL.deletingPathExtension().lastPathComponent)
        } else if auto {
            runAutomatedTest(server: server)
        } else if tui || mpv || termkit {
            if mpv {
                try runMpvTUIMode(server: server, duration: mediaInfo.duration)
            } else if termkit {
                throw ValidationError("TermKit mode currently requires --mpv or --chromecast")
            } else {
                throw ValidationError("TUI mode requires --mpv or --chromecast (ffplay fallback is no longer supported)")
            }
        } else {
            runInteractiveMode(server: server)
        }
    }

    private func runAutomatedTest(server: TranscodeServer) {
        server.onProgress = { position in
            print("[PROGRESS] \(formatTime(position))")
        }

        print("Running automated test sequence...")
        print("(Launch ffplay now to see the video)")
        print("")

        // Wait for ffplay to connect
        print("[TEST] Waiting 5s for player to connect...")
        sleep(5)

        // Step 1: Play from start for 15s
        print("")
        print("[TEST] Step 1: Playing from start for 15s...")
        sleep(15)

        // Step 2: Seek to 30:00
        print("")
        print("[TEST] Step 2: Seeking to 30:00...")
        server.seek(to: 30 * 60)  // 30 minutes
        sleep(15)

        // Step 3: Pause
        print("")
        print("[TEST] Step 3: Pausing for 3s...")
        server.pause()
        sleep(3)

        // Step 4: Seek to 15:00
        print("")
        print("[TEST] Step 4: Seeking to 15:00...")
        server.seek(to: 15 * 60)  // 15 minutes

        // Step 5: Resume
        print("")
        print("[TEST] Step 5: Resuming playback...")
        server.resume()
        sleep(15)  // Play till ~15:15

        // Step 6: Final pause
        print("")
        print("[TEST] Step 6: Final pause...")
        server.pause()

        print("")
        print("========================================")
        print("[TEST] Automated test complete!")
        print("========================================")
        print("")
        print("Press Ctrl+C to stop server")

        // Keep running
        setupSignalHandler(server: server)
        dispatchMain()
    }

    private func runMpvTUIMode(server: TranscodeServer, duration: TimeInterval) throws {
        let controller = MpvController()
        _ = try controller.launch(url: server.url, windowTitle: "Beamy Player (mpv)")
        let player = MpvPlayer(controller: controller, server: server, streamURL: server.url)
        if termkit {
            let ui = TermKitTranscoderUI(player: player, duration: duration)
            try ui.run()
        } else {
            let tui = TranscoderTUI(
                server: server,
                duration: duration,
                player: player,
                playerLabel: "mpv IPC",
                onCleanup: {
                    controller.quit()
                }
            )
            try tui.run()
        }
    }

    private func runChromecastMode(server: TranscodeServer, duration: TimeInterval, deviceNameOrIP: String, title: String) throws {
        let device = try resolveDevice(nameOrIP: deviceNameOrIP)
        print("Connecting to Chromecast: \(device.name)...")
        let client = CastV2Client(device: device, verbose: true)
        try client.connect()
        try client.launchDefaultMediaReceiver()
        try client.loadMedia(url: server.url, contentType: "video/mp2t", title: title, isLive: true)
        let player = ChromecastPlayer(client: client)
        if termkit {
            let ui = TermKitTranscoderUI(player: player, duration: duration)
            try ui.run()
        } else {
            let tui = TranscoderTUI(
                server: server,
                duration: duration,
                player: player,
                playerLabel: "chromecast"
            )
            try tui.run()
        }
    }

    private func resolveDevice(nameOrIP: String) throws -> ChromecastDevice {
        if let device = try ChromecastDiscovery.findDevice(named: nameOrIP, timeout: 5.0) {
            return device
        }
        throw ValidationError("Chromecast device not found: \(nameOrIP)")
    }

    private func runInteractiveMode(server: TranscodeServer) {
        server.onProgress = { position in
            print("[PROGRESS] \(formatTime(position))")
        }

        print("Interactive mode - commands:")
        print("  p     - pause")
        print("  r     - resume")
        print("  s XXX - seek to XXX seconds")
        print("  q     - quit")
        print("")

        setupSignalHandler(server: server)

        // Read commands from stdin
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()

            if trimmed == "p" {
                print("Pausing...")
                server.pause()
            } else if trimmed == "r" {
                print("Resuming...")
                server.resume()
            } else if trimmed.hasPrefix("s"), let match = trimmed.firstMatch(of: /^s\s*(.+)/) {
                let timeStr = String(match.1)
                if let seconds = parseTime(timeStr) {
                    print("Seeking to \(formatTime(seconds))...")
                    server.seek(to: seconds)
                } else {
                    print("Invalid time format. Use seconds (e.g., 's1800' or 's 30:00')")
                }
            } else if trimmed == "q" {
                print("Stopping...")
                server.stop()
                return
            } else if !trimmed.isEmpty {
                print("Unknown command: \(trimmed)")
            }
        }
    }

    private func setupSignalHandler(server: TranscodeServer) {
        signal(SIGINT) { _ in
            print("\nStopping server...")
            Darwin.exit(0)
        }
    }

    private func parseTime(_ str: String) -> TimeInterval? {
        // Try parsing as seconds
        if let seconds = Double(str) {
            return seconds
        }

        // Try parsing as MM:SS or HH:MM:SS
        let parts = str.split(separator: ":")
        if parts.count == 2,
           let m = Double(parts[0]),
           let s = Double(parts[1]) {
            return m * 60 + s
        }
        if parts.count == 3,
           let h = Double(parts[0]),
           let m = Double(parts[1]),
           let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        }

        return nil
    }
}

// MARK: - TUI Mode (Player-backed)

class TranscoderTUI: @unchecked Sendable {
    private let server: TranscodeServer
    private let duration: TimeInterval
    private let player: Player
    private let playerLabel: String
    private let onCleanup: (() -> Void)?

    private var isRunning = true
    private var oldTermios: termios?
    private let logFile = "/tmp/beamy-tui.log"
    private var lastKnownPlayerPaused: Bool = false
    private var lastKnownPosition: TimeInterval = 0

    init(server: TranscodeServer, duration: TimeInterval, player: Player, playerLabel: String, onCleanup: (() -> Void)? = nil) {
        self.server = server
        self.duration = duration
        self.player = player
        self.playerLabel = playerLabel
        self.onCleanup = onCleanup
    }

    func run() throws {
        // Clear screen and hide cursor
        print("\u{001B}[2J\u{001B}[?25l")
        print("\u{001B}[10;1H" + "Using \(playerLabel)".green)

        // Start display update thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.isRunning == true {
                self?.drawUI()
                usleep(250_000) // Update every 250ms
            }
        }

        // Enable raw mode for single-key input
        enableRawMode()
        defer { cleanup() }

        // Draw initial UI
        sleep(1)

        // Move cursor to input line (line 12)
        print("\u{001B}[12;1H\u{001B}[K")
        fflush(stdout)

        var inputBuffer = ""

        // Raw input loop - process keypresses immediately
        while isRunning {
            var char: UInt8 = 0
            let result = read(STDIN_FILENO, &char, 1)

            guard result > 0 else { continue }

            switch char {
            case 27: // ESC - check for arrow keys
                if inputBuffer.isEmpty {
                    var seq1: UInt8 = 0, seq2: UInt8 = 0
                    if read(STDIN_FILENO, &seq1, 1) > 0 && seq1 == 91 { // '['
                        if read(STDIN_FILENO, &seq2, 1) > 0 {
                            switch seq2 {
                            case 68: // Left arrow
                                scrubBackward()
                            case 67: // Right arrow
                                scrubForward()
                            default:
                                break
                            }
                        }
                    }
                }
            case 32: // Spacebar
                if inputBuffer.isEmpty {
                    togglePlayPause()
                } else {
                    inputBuffer.append(" ")
                    print("\u{001B}[12;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            case 113: // 'q'
                if inputBuffer.isEmpty {
                    isRunning = false
                } else {
                    inputBuffer.append("q")
                    print("\u{001B}[12;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            case 10, 13: // Enter - submit command
                let cmd = inputBuffer.trimmingCharacters(in: .whitespaces).lowercased()
                if cmd.hasPrefix("s") {
                    let numPart = cmd.dropFirst().trimmingCharacters(in: .whitespaces)
                    if let seconds = Double(numPart) {
                        log("Seeking to \(seconds)s")
                        seek(to: seconds)
                    }
                }
                inputBuffer = ""
                print("\u{001B}[12;1H\u{001B}[K> ", terminator: "")
                fflush(stdout)
            case 127, 8: // Backspace
                if !inputBuffer.isEmpty {
                    inputBuffer.removeLast()
                    print("\u{001B}[12;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            default:
                if char >= 32 && char < 127 {
                    inputBuffer.append(Character(UnicodeScalar(char)))
                    print("\u{001B}[12;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            }
        }
    }

    // MARK: - Playback Control

    private func scrubBackward() {
        scrub(offset: -10)
    }

    private func scrubForward() {
        scrub(offset: 10)
    }

    private func scrub(offset: TimeInterval) {
        let currentTime = getCurrentPosition()
        let newPosition = max(0, currentTime + offset)
        seek(to: newPosition)
    }

    private func togglePlayPause() {
        do {
            let paused = try player.isPaused()
            if paused {
                try player.resume()
            } else {
                try player.pause()
            }
        } catch {
            // Fallback to server-only control if player unavailable
            server.togglePlayPause()
        }
    }

    private func seek(to time: TimeInterval) {
        do {
            try player.seek(to: time)
        } catch {
            server.seek(to: time)
        }
    }

    private func getCurrentPosition() -> TimeInterval {
        if let position = try? player.getPosition() {
            lastKnownPosition = position
            return position
        }
        return lastKnownPosition
    }

    private func getIsPaused() -> Bool {
        if let paused = try? player.isPaused() {
            lastKnownPlayerPaused = paused
            return paused
        }
        return lastKnownPlayerPaused
    }

    // MARK: - UI Drawing

    private func drawUI() {
        print("\u{001B}7", terminator: "") // Save cursor
        print("\u{001B}[1;1H", terminator: "") // Move to top

        let currentPosition = getCurrentPosition()
        let isPaused = getIsPaused()

        let percent = duration > 0 ? (currentPosition / duration) * 100 : 0
        let barWidth = 50
        let filled = Int((currentPosition / max(1, duration)) * Double(barWidth))
        let filledBar = String(repeating: "━", count: min(filled, barWidth)).green.bold
        let emptyBar = String(repeating: "─", count: max(0, barWidth - filled - 1)).lightBlack
        let bar = filledBar + "●".green.bold + emptyBar

        let statusIcon = isPaused ? "▶".green : "⏸".yellow
        let timeDisplay = "\(formatTime(currentPosition).bold) / \(formatTime(duration))"
        let percentDisplay = "(\(String(format: "%.1f", percent).yellow)%)"

        let playerMode = "[\(playerLabel)]".green

        print("┌─ Beamy Transcoder \(playerMode) ────────────────────────────────┐".cyan.bold + "\u{001B}[K")
        print("│                                                             │".cyan + "\u{001B}[K")
        print("│  \(statusIcon)  \(timeDisplay)  \(percentDisplay)".cyan + "\u{001B}[K")
        print("│                                                             │".cyan + "\u{001B}[K")
        print("│  \(bar)  │".cyan + "\u{001B}[K")
        print("│                                                             │".cyan + "\u{001B}[K")
        print("├─ Commands ──────────────────────────────────────────────────┤".cyan.bold + "\u{001B}[K")
        print("│  ".cyan + "[SPACE]".green.bold + " = Pause/Resume  ".cyan + "[←/→]".green.bold + " = -10s/+10s  ".cyan + "[s 30]".green.bold + " = Seek".cyan + "\u{001B}[K")
        print("│  ".cyan + "[q]".green.bold + " = Quit".cyan + "                                                  │".cyan + "\u{001B}[K")
        print("└─────────────────────────────────────────────────────────────┘".cyan.bold + "\u{001B}[K")

        print("\u{001B}8", terminator: "") // Restore cursor
        fflush(stdout)
    }

    // MARK: - Helpers

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00:00" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Terminal Control

    private func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        oldTermios = raw
        raw.c_lflag &= ~(UInt(ECHO | ICANON))
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    private func cleanup() {
        isRunning = false
        showCursor()
        if var old = oldTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &old)
        }
        print("\n")
        onCleanup?()
        server.stop()
    }

    private func showCursor() {
        print("\u{001B}[?25h", terminator: "")
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite && !seconds.isNaN else { return "00:00:00" }
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}
