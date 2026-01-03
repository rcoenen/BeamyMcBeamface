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

    func run() throws {
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

        if auto {
            runAutomatedTest(server: server)
        } else if tui {
            try runTUIMode(server: server, duration: mediaInfo.duration)
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

    private func runTUIMode(server: TranscodeServer, duration: TimeInterval) throws {
        let tui = TranscoderTUI(server: server, duration: duration)
        try tui.run()
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
            } else if trimmed.hasPrefix("s ") {
                let timeStr = String(trimmed.dropFirst(2))
                if let seconds = parseTime(timeStr) {
                    print("Seeking to \(formatTime(seconds))...")
                    server.seek(to: seconds)
                } else {
                    print("Invalid time format. Use seconds (e.g., 's 1800' for 30:00)")
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

// MARK: - TUI Mode (mpv-inspired)

class TranscoderTUI: @unchecked Sendable {
    private let server: TranscodeServer
    private let duration: TimeInterval
    private var needsRedraw = true

    private var oldTermios: termios?

    init(server: TranscodeServer, duration: TimeInterval) {
        self.server = server
        self.duration = duration

        // Listen for state changes from server
        server.onStateChanged = { [weak self] isPaused, position in
            self?.needsRedraw = true
        }

        // Keep progress callback for backward compatibility / debugging
        server.onProgress = { [weak self] position in
            self?.needsRedraw = true
        }
    }

    func run() throws {
        // Clear screen and hide cursor
        print("\u{001B}[2J\u{001B}[?25l")

        // Launch ffplay first
        launchFFplayDetached()

        // Wait for ffplay to connect
        sleep(2)

        // Start display update thread
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                self.drawUI()
                usleep(500_000) // Update every 500ms
            }
        }

        // Enable raw mode for single-key input
        enableRawMode()
        defer { cleanup() }

        // Draw initial UI
        sleep(1)

        // Move cursor to input line (line 11)
        print("\u{001B}[11;1H\u{001B}[K")
        fflush(stdout)

        var inputBuffer = ""
        var running = true

        // Raw input loop - process keypresses immediately
        while running {
            var char: UInt8 = 0
            let result = read(STDIN_FILENO, &char, 1)

            guard result > 0 else { continue }

            switch char {
            case 32: // Spacebar
                if inputBuffer.isEmpty {
                    // Only toggle if not typing a command
                    server.togglePlayPause()
                } else {
                    // Add space to command being typed
                    inputBuffer.append(" ")
                    print("\u{001B}[11;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            case 113: // 'q'
                if inputBuffer.isEmpty {
                    server.stop()
                    running = false
                } else {
                    // Add 'q' to command
                    inputBuffer.append("q")
                    print("\u{001B}[11;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            case 10, 13: // Enter - submit command
                let cmd = inputBuffer.trimmingCharacters(in: .whitespaces).lowercased()
                if cmd.hasPrefix("s ") {
                    let timeStr = String(cmd.dropFirst(2))
                    if let seconds = Double(timeStr) {
                        // Seek method now handles pause state preservation automatically
                        server.seek(to: seconds)
                    }
                }
                inputBuffer = ""
                print("\u{001B}[11;1H\u{001B}[K> ", terminator: "")
                fflush(stdout)
            case 127, 8: // Backspace
                if !inputBuffer.isEmpty {
                    inputBuffer.removeLast()
                    print("\u{001B}[11;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            default:
                if char >= 32 && char < 127 { // Printable ASCII
                    inputBuffer.append(Character(UnicodeScalar(char)))
                    print("\u{001B}[11;1H\u{001B}[K> \(inputBuffer)", terminator: "")
                    fflush(stdout)
                }
            }
        }
    }

    private func drawUI() {
        // Save cursor position, move to top, draw UI, restore cursor
        // This prevents clearing the input line where user is typing
        print("\u{001B}7", terminator: "") // Save cursor position
        print("\u{001B}[1;1H", terminator: "") // Move to line 1, col 1

        // Query server for current state - server is single source of truth
        let currentPosition = server.currentPosition
        let isPaused = server.isPaused

        let percent = duration > 0 ? (currentPosition / duration) * 100 : 0
        let barWidth = 50
        let filled = Int((currentPosition / max(1, duration)) * Double(barWidth))
        let filledBar = String(repeating: "━", count: min(filled, barWidth)).green.bold
        let emptyBar = String(repeating: "─", count: max(0, barWidth - filled - 1)).lightBlack
        let bar = filledBar + "●".green.bold + emptyBar

        // Status icon shows NEXT action (not current state)
        // Playing → show pause icon (will pause when pressed)
        // Paused → show play icon (will play when pressed)
        let statusIcon = isPaused ? "▶".green : "⏸".yellow
        let timeDisplay = "\(formatTime(currentPosition).bold) / \(formatTime(duration))"
        let percentDisplay = "(\(String(format: "%.1f", percent).yellow)%)"

        // Draw UI box (9 lines total)
        print("┌─ Beamy Transcoder ─────────────────────────────────────────┐".cyan.bold + "\u{001B}[K")
        print("│                                                             │".cyan + "\u{001B}[K")
        print("│  \(statusIcon)  \(timeDisplay)  \(percentDisplay)".cyan + "\u{001B}[K")
        print("│                                                             │".cyan + "\u{001B}[K")
        print("│  \(bar)  │".cyan + "\u{001B}[K")
        print("│                                                             │".cyan + "\u{001B}[K")
        print("├─ Commands ──────────────────────────────────────────────────┤".cyan.bold + "\u{001B}[K")
        print("│  ".cyan + "[SPACE]".green.bold + " = Pause/Resume    ".cyan + "[s 30]".green.bold + " = Seek to 30s    ".cyan + "[q]".green.bold + " = Quit".cyan + "\u{001B}[K")
        print("└─────────────────────────────────────────────────────────────┘".cyan.bold + "\u{001B}[K")

        print("\u{001B}8", terminator: "") // Restore cursor position
        fflush(stdout)
    }

    private func launchFFplayDetached() {
        // Launch ffplay via shell to completely detach from our process
        // This avoids any terminal/tty inheritance issues
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "exec ffplay -i '\(server.url.absoluteString)' -window_title 'Beamy Player' -autoexit -loglevel quiet"
        ]
        // Create new file handles to avoid inheriting our terminal
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        // Run async so we don't block
        DispatchQueue.global(qos: .userInitiated).async {
            try? task.run()
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00:00" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // Old TUI methods - keeping for reference but not used
    private func seekToPercent(_ percent: Int) {
        let newPos = (Double(percent) / 100.0) * duration
        server.seek(to: newPos)
        needsRedraw = true
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
        showCursor()
        if var old = oldTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &old)
        }
        print("\n")
        server.stop()
    }

    private func clearScreen() {
        print("\u{001B}[2J", terminator: "")
    }

    private func moveCursor(row: Int, col: Int) {
        print("\u{001B}[\(row);\(col)H", terminator: "")
    }

    private func hideCursor() {
        print("\u{001B}[?25l", terminator: "")
    }

    private func showCursor() {
        print("\u{001B}[?25h", terminator: "")
    }

    private func clearToEnd() {
        print("\u{001B}[J", terminator: "")
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite && !seconds.isNaN else { return "00:00:00" }
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}
