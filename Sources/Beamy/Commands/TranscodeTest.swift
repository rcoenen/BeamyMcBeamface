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

        if auto {
            runAutomatedTest(server: server)
        } else if tui || mpv {
            try runTUIMode(server: server, duration: mediaInfo.duration, useMpv: mpv)
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

    private func runTUIMode(server: TranscodeServer, duration: TimeInterval, useMpv: Bool) throws {
        let tui = TranscoderTUI(server: server, duration: duration, useMpv: useMpv)
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

// MARK: - TUI Mode (supports both ffplay and mpv)

class TranscoderTUI: @unchecked Sendable {
    private let server: TranscodeServer
    private let duration: TimeInterval
    private let useMpv: Bool
    private var needsRedraw = true

    private var oldTermios: termios?
    private var mpvController: MpvController?
    private var isRunning = true
    private var lastSeekPosition: TimeInterval = 0
    private var lastSeekTime: Date?

    init(server: TranscodeServer, duration: TimeInterval, useMpv: Bool = false) {
        self.server = server
        self.duration = duration
        self.useMpv = useMpv

        if !useMpv {
            // ffplay mode: Listen for state changes from server
            server.onStateChanged = { [weak self] isPaused, position in
                self?.needsRedraw = true
            }

            server.onProgress = { [weak self] position in
                self?.needsRedraw = true
            }
        }
        // mpv mode: We'll poll mpv directly for position
    }

    func run() throws {
        // Clear screen and hide cursor
        print("\u{001B}[2J\u{001B}[?25l")

        if useMpv {
            try launchMpv()
            print("\u{001B}[10;1H" + "Using mpv with IPC (accurate position)".green)
        } else {
            launchFFplayDetached()
            print("\u{001B}[10;1H" + "Using ffplay (position may lag ~7s)".yellow)
        }

        // Wait for player to connect
        sleep(2)

        // Start display update thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.isRunning == true {
                self?.drawUI()
                usleep(250_000) // Update every 250ms (faster for mpv accuracy)
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
        log("=== SCRUB START \(offset > 0 ? "→" : "←") offset=\(offset)s ===")

        // Use server.currentPosition as source of truth since it tracks FFmpeg PTS accurately
        let currentTime = getCurrentPosition()
        log("SCRUB: Using server.currentPosition: \(currentTime)s")

        // Calculate new position and seek
        let newPosition = max(0, currentTime + offset)
        log("SCRUB: Calculation: \(currentTime)s + \(offset)s = \(newPosition)s")
        seek(to: newPosition)
        log("=== SCRUB END ===")
    }

    private func togglePlayPause() {
        if useMpv, let mpv = mpvController {
            do {
                let paused = try mpv.isPaused()
                if paused {
                    // Resume: first FFmpeg, then mpv
                    server.resume()
                    try mpv.resume()
                } else {
                    // Pause: first mpv (instant), then FFmpeg (stop buffer growth)
                    try mpv.pause()
                    server.pause()
                }
            } catch {
                // Fallback to server-only control
                server.togglePlayPause()
            }
        } else {
            server.togglePlayPause()
        }
    }

    private func seek(to time: TimeInterval) {
        log("=== SEEK to \(time)s ===")
        lastSeekPosition = time
        lastSeekTime = Date()
        if useMpv, let mpv = mpvController {
            // Server prepares for reconnect, kills FFmpeg
            server.seek(to: time, awaitClientReconnect: true)
            // Tell mpv to reload - clears buffer, reconnects
            try? mpv.reloadStream(server.url)

            // Wait for mpv to reconnect and FFmpeg to restart before pausing
            // Otherwise pause() returns early because FFmpeg isn't running yet
            usleep(300_000)  // 300ms - enough for reconnect + FFmpeg startup

            // Pause after seek so user sees the frame
            server.pause()
            try? mpv.pause()
        } else {
            server.seek(to: time)
            server.pause()
        }
    }

    private func getCurrentPosition() -> TimeInterval {
        // After a seek, mpv takes time to reload - playback-time is stale
        // Use the seek target directly during the grace period
        if let seekTime = lastSeekTime, Date().timeIntervalSince(seekTime) < 2 {
            return lastSeekPosition
        }

        if useMpv, let mpv = mpvController {
            do {
                // mpv's playback-time resets after each stream reload (seek).
                // But we can use it as a relative offset: actual = seekTarget + playback-time
                let playbackTime = try mpv.getPosition()
                let actual = lastSeekPosition + playbackTime
                return actual
            } catch {
                // Fallback to server position if mpv query fails
                return server.currentPosition
            }
        }
        return server.currentPosition
    }

    private func getIsPaused() -> Bool {
        // During seek grace period, we know we'll end up paused (seek always pauses)
        // Show paused state immediately to avoid icon flicker
        if let seekTime = lastSeekTime, Date().timeIntervalSince(seekTime) < 0.5 {
            return true
        }

        if useMpv, let mpv = mpvController {
            do {
                return try mpv.isPaused()
            } catch {
                return server.isPaused
            }
        }
        return server.isPaused
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

        let playerMode = useMpv ? "[mpv IPC]".green : "[ffplay]".yellow

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

    // MARK: - Player Launch

    private func launchMpv() throws {
        mpvController = MpvController()
        _ = try mpvController?.launch(url: server.url, windowTitle: "Beamy Player (mpv)")
    }

    private func launchFFplayDetached() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "exec ffplay -i '\(server.url.absoluteString)' -window_title 'Beamy Player' -autoexit -loglevel quiet"
        ]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            try? task.run()
        }
    }

    // MARK: - Helpers

    private let logFile = "/tmp/beamy-tui.log"

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
        mpvController?.quit()
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
