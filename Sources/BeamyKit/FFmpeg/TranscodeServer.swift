import Darwin
import Foundation

/// A simple HTTP server that serves transcoded media content.
///
/// Architecture:
/// - HTTP server accepts client connections and keeps them open
/// - FFmpeg process is managed separately and can be restarted (for seek)
/// - On seek: kill FFmpeg, restart at new position, continue streaming to same socket
public final class TranscodeServer: @unchecked Sendable {
    private let input: URL
    private let port: Int
    private let mediaInfo: MediaInfo
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var ffmpegProcess: Process?
    private var currentSeekPosition: TimeInterval = 0

    // Client socket stored at class level so seek can reuse it
    private var clientSocket: Int32 = -1
    private var streamingQueue: DispatchQueue?
    private var isStreaming = false
    private var ptsTracker = MpegTsPtsTracker()
    private var pendingSeekPauseAt: TimeInterval?
    private var awaitingClientReconnect = false

    // Keep pipes alive at class level to prevent deallocation
    private var outputPipe: Pipe?
    private var stderrPipe: Pipe?

    // MARK: - Playback State (Single Source of Truth)

    /// Current pause state - true if FFmpeg is paused (SIGSTOP)
    public private(set) var isPaused: Bool = false

    /// Current playback position derived from outgoing stream timestamps (PTS).
    public private(set) var currentPosition: TimeInterval = 0

    /// Callback for state changes (isPaused, currentPosition)
    public var onStateChanged: ((_ isPaused: Bool, _ position: TimeInterval) -> Void)?

    // Debug logging to file
    private static let debugLog: FileHandle? = {
        let logPath = "/tmp/beamy-transcoder-debug.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        return FileHandle(forWritingAtPath: logPath)
    }()

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            Self.debugLog?.write(data)
        }
    }

    /// Callback for progress updates (current time in seconds, source position)
    public var onProgress: (@Sendable (TimeInterval) -> Void)?

    public var url: URL {
        URL(string: "http://\(getLocalIPAddress()):\(port)/stream.ts")!
    }

    public init(input: URL, port: Int, mediaInfo: MediaInfo) throws {
        self.input = input
        self.port = port
        self.mediaInfo = mediaInfo
        signal(SIGPIPE, SIG_IGN)
        try startServer()
    }

    private func startServer() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw TranscodeServerError.socketCreationFailed
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else {
            close(serverSocket)
            throw TranscodeServerError.bindFailed(port)
        }

        guard listen(serverSocket, 5) >= 0 else {
            close(serverSocket)
            throw TranscodeServerError.listenFailed
        }

        isRunning = true

        // Handle connections in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptConnections()
        }
    }

    private func acceptConnections() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let newClientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientAddrLen)
                }
            }

            guard newClientSocket >= 0 else { continue }

            // Store client socket and start streaming
            handleNewConnection(newClientSocket)
        }
    }

    private func handleNewConnection(_ socket: Int32) {
        prepareForNewClient()

        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        log("Client connected on socket \(socket)")

        // Read HTTP request (just consume it)
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(socket, &buffer, buffer.count, 0)

        // Send HTTP response headers
        let headers = """
        HTTP/1.0 200 OK\r
        Content-Type: video/mp2t\r
        Access-Control-Allow-Origin: *\r
        Cache-Control: no-cache\r
        \r

        """
        _ = headers.withCString { send(socket, $0, strlen($0), 0) }

        // Store socket and start FFmpeg
        self.clientSocket = socket
        self.isStreaming = true
        self.awaitingClientReconnect = false

        // Create dedicated queue for this streaming session
        self.streamingQueue = DispatchQueue(label: "com.beamy.streaming", qos: .userInitiated)

        // Start FFmpeg at current seek position
        startFFmpeg(at: currentSeekPosition)
    }

    private func prepareForNewClient() {
        isStreaming = false

        if clientSocket >= 0 {
            log("Closing previous client socket \(clientSocket)")
            shutdown(clientSocket, SHUT_RDWR)
            close(clientSocket)
            clientSocket = -1
        }

        if let process = ffmpegProcess, process.isRunning {
            log("Terminating FFmpeg for new client")
            process.terminate()
            process.waitUntilExit()
            ffmpegProcess = nil
            log("Old FFmpeg terminated for new client")
        }
    }

    /// Start FFmpeg at the given position and stream to current client socket
    private func startFFmpeg(at position: TimeInterval) {
        guard clientSocket >= 0 else {
            log("No client socket, cannot start FFmpeg")
            return
        }

        ptsTracker.reset(baseline: position)

        let config = (try? Config.load().ffmpeg) ?? .default
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: config.ffmpegPath)

        // Build arguments with seek position and progress reporting
        var args: [String] = []

        // Seek position (before input for fast seek)
        if position > 0 {
            args += ["-ss", String(format: "%.3f", position)]
        }

        // Preserve original timestamps so progress reflects source position
        args += ["-copyts"]

        // Input file
        args += ["-i", input.path]

        // Progress output to stderr (parsed for position feedback)
        // Update every 0.5 seconds for smooth UI updates
        args += ["-progress", "pipe:2", "-stats_period", "0.5"]

        // Video settings
        args += [
            "-map", "0:v:0",
            "-map", "0:a:0?",  // Optional audio
            "-sn",
            "-c:v", "libx264",
            "-profile:v", "baseline",
            "-level", "3.1",
            "-preset", config.preset,
            "-crf", "\(config.crf)",
        ]

        // Audio settings
        args += [
            "-c:a", "aac",
            "-ac", "2",
            "-ar", "44100",
            "-b:a", config.audioBitrate,
        ]

        // Output format - flush immediately to prevent buffering issues
        args += [
            "-flush_packets", "1",
            "-fflags", "+flush_packets",
            "-f", "mpegts",
            "pipe:1"
        ]

        ffmpeg.arguments = args
        log("FFmpeg args: \(args.joined(separator: " "))")

        // Store pipes at class level to prevent deallocation
        let newOutputPipe = Pipe()
        let newStderrPipe = Pipe()
        self.outputPipe = newOutputPipe
        self.stderrPipe = newStderrPipe
        ffmpeg.standardOutput = newOutputPipe
        ffmpeg.standardError = newStderrPipe

        // CRITICAL: Detach FFmpeg from terminal stdin to prevent blocking.
        // Without this, FFmpeg inherits the parent's terminal stdin. When running
        // interactively, FFmpeg waits for terminal access before writing to stdout,
        // causing the stream to hang until a SIGSTOP/SIGCONT cycle "kicks" it.
        // Setting stdin to /dev/null breaks the terminal association completely.
        ffmpeg.standardInput = FileHandle.nullDevice

        // Set up handles before starting anything
        let clientSocket = self.clientSocket
        let outputHandle = newOutputPipe.fileHandleForReading
        let stderrHandle = newStderrPipe.fileHandleForReading
        // Start the reading threads BEFORE FFmpeg to prevent pipe buffer deadlock
        let streamingStarted = DispatchSemaphore(value: 0)
        let stderrStarted = DispatchSemaphore(value: 0)

        // Stream video data to client socket - MUST start before FFmpeg
        Thread.detachNewThread { [weak self] in
            streamingStarted.signal()  // Signal that we're ready to read
            while self?.isStreaming == true {
                let data = outputHandle.availableData
                if data.isEmpty { break }
                if let latestPts = self?.ptsTracker.consume(data) {
                    self?.updatePositionFromPts(latestPts)
                }
                let sent = data.withUnsafeBytes { send(clientSocket, $0.baseAddress, data.count, 0) }
                if sent < 0 {
                    self?.log("send() failed, stopping stream")
                    self?.isStreaming = false
                    break
                }
            }
            self?.log("Streaming thread exiting, isStreaming=\(self?.isStreaming ?? false)")
        }

        // Parse stderr for progress (debug only; not used for currentPosition).
        Thread.detachNewThread { [weak self] in
            stderrStarted.signal()  // Signal that we're ready to read
            var textBuffer = ""
            // Keep reading while streaming is active
            while self?.isStreaming == true {
                let data = stderrHandle.availableData
                if data.isEmpty {
                    self?.log("Progress: No data, sleeping...")
                    usleep(100_000) // Sleep 100ms and retry
                    continue
                }
                if let text = String(data: data, encoding: .utf8) {
                    textBuffer += text
                    self?.log("Progress received: \(text)")

                    // Parse out_time=HH:MM:SS.ffffff from -progress output
                    // out_time is the timestamp of frames being output to ffplay
                    // With -copyts, this reflects the actual source file position
                    if let range = textBuffer.range(of: #"out_time=(\d{2}):(\d{2}):(\d{2}\.\d+)"#, options: .regularExpression) {
                        let timeStr = textBuffer[range].dropFirst(9) // Remove "out_time="
                        self?.log("Matched time string: \(timeStr)")
                        let parts = timeStr.split(separator: ":")
                        if parts.count == 3,
                           let h = Double(parts[0]),
                           let m = Double(parts[1]),
                           let s = Double(parts[2]) {
                            let position = h * 3600 + m * 60 + s
                            self?.log("FFmpeg out_time position: \(position)")
                        }
                    }

                    // Clear buffer after progress=continue/end line
                    if textBuffer.contains("progress=") {
                        textBuffer = ""
                    }
                }
            }
            self?.log("Progress thread exiting, isStreaming=\(self?.isStreaming ?? false)")
        }

        // Wait for both reading threads to be ready
        streamingStarted.wait()
        stderrStarted.wait()

        // NOW start FFmpeg - readers are already waiting for data
        do {
            try ffmpeg.run()
            self.ffmpegProcess = ffmpeg
            log("FFmpeg started at position \(formatTime(position))")
        } catch {
            log("Failed to start FFmpeg: \(error)")
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    public func stop() {
        isRunning = false
        isStreaming = false
        ffmpegProcess?.terminate()
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    public func pause() {
        guard !isPaused, let process = ffmpegProcess, process.isRunning else { return }

        isPaused = true
        pendingSeekPauseAt = nil
        kill(process.processIdentifier, SIGSTOP)

        onStateChanged?(isPaused, currentPosition)
        log("Paused at \(formatTime(currentPosition))")
    }

    public func resume() {
        guard isPaused, let process = ffmpegProcess, process.isRunning else { return }

        isPaused = false
        pendingSeekPauseAt = nil
        kill(process.processIdentifier, SIGCONT)

        onStateChanged?(isPaused, currentPosition)
        log("Resumed at \(formatTime(currentPosition))")
    }

    private func forcePause() {
        guard let process = ffmpegProcess, process.isRunning else { return }

        isPaused = true
        pendingSeekPauseAt = nil
        kill(process.processIdentifier, SIGSTOP)
        onStateChanged?(isPaused, currentPosition)
        log("Paused at \(formatTime(currentPosition))")
    }

    /// Toggle between play and pause
    public func togglePlayPause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    /// Seek to a new position by restarting FFmpeg
    /// The HTTP connection stays open - only FFmpeg restarts
    public func seek(to time: TimeInterval) {
        seek(to: time, awaitClientReconnect: false)
    }

    public func seek(to time: TimeInterval, awaitClientReconnect: Bool) {
        log("Seeking to \(formatTime(time))...")

        // Update seek position for FFmpeg -ss argument
        currentSeekPosition = time

        // Reset currentPosition - will be updated by PTS once packets flow
        currentPosition = time

        if awaitClientReconnect {
            awaitingClientReconnect = true
            pendingSeekPauseAt = time
            log("Awaiting client reconnect for seek")
            prepareForNewClient()
        } else {
            // Stop current FFmpeg
            if let process = ffmpegProcess, process.isRunning {
                // First resume if stopped (SIGTERM won't work on stopped process)
                kill(process.processIdentifier, SIGCONT)
                process.terminate()
                process.waitUntilExit()
                log("Old FFmpeg terminated")
            }

            // Start new FFmpeg at new position (same client socket)
            startFFmpeg(at: time)
            pendingSeekPauseAt = time
        }

        // End seek in paused state, but wait until new PTS arrives so the
        // receiver has a frame from the seek target before we stop.
        isPaused = false
        onStateChanged?(isPaused, currentPosition)
    }

    private func updatePositionFromPts(_ position: TimeInterval) {
        // Guard against backwards jumps from jitter; seeks reset the baseline.
        if position + 0.5 < currentPosition {
            return
        }

        currentPosition = position
        onProgress?(position)
        onStateChanged?(isPaused, position)

        if let pending = pendingSeekPauseAt, position >= pending {
            forcePause()
        }
    }

    private func getLocalIPAddress() -> String {
        var address = "127.0.0.1"

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return address
        }

        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        address = String(decoding: bytes, as: UTF8.self)
                        break
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        return address
    }

    deinit {
        stop()
    }
}

private final class MpegTsPtsTracker {
    private var buffer = Data()
    private var lastPtsSeconds: TimeInterval?

    func reset(baseline: TimeInterval) {
        buffer.removeAll(keepingCapacity: true)
        lastPtsSeconds = baseline
    }

    func consume(_ data: Data) -> TimeInterval? {
        buffer.append(data)
        var latest: TimeInterval?

        while buffer.count >= 188 {
            if buffer[buffer.startIndex] != 0x47 {
                if let syncIndex = buffer.firstIndex(of: 0x47) {
                    buffer.removeSubrange(buffer.startIndex..<syncIndex)
                } else {
                    buffer.removeAll(keepingCapacity: true)
                    break
                }
                if buffer.count < 188 {
                    break
                }
            }

            let packet = buffer.prefix(188)
            if let pts = parsePts(from: packet) {
                lastPtsSeconds = pts
                latest = pts
            }
            buffer.removeFirst(188)
        }

        return latest
    }

    private func parsePts(from packet: Data) -> TimeInterval? {
        guard packet.count >= 188 else { return nil }
        if packet[packet.startIndex] != 0x47 {
            return nil
        }

        let b1 = packet[packet.startIndex + 1]
        let b3 = packet[packet.startIndex + 3]
        let payloadUnitStart = (b1 & 0x40) != 0
        let adaptationFieldControl = (b3 & 0x30) >> 4

        if adaptationFieldControl == 0 || adaptationFieldControl == 2 {
            return nil
        }

        var payloadOffset = 4
        if adaptationFieldControl == 3 {
            let adaptationLength = Int(packet[packet.startIndex + 4])
            payloadOffset += 1 + adaptationLength
            if payloadOffset >= 188 {
                return nil
            }
        }

        guard payloadUnitStart else { return nil }
        if payloadOffset + 9 >= 188 {
            return nil
        }

        if packet[packet.startIndex + payloadOffset] != 0x00 ||
            packet[packet.startIndex + payloadOffset + 1] != 0x00 ||
            packet[packet.startIndex + payloadOffset + 2] != 0x01 {
            return nil
        }

        let streamId = packet[packet.startIndex + payloadOffset + 3]
        if streamId < 0xE0 || streamId > 0xEF {
            return nil
        }

        let ptsDtsFlags = packet[packet.startIndex + payloadOffset + 7]
        if (ptsDtsFlags & 0x80) == 0 {
            return nil
        }

        let ptsOffset = payloadOffset + 9
        if ptsOffset + 4 >= 188 {
            return nil
        }

        let p0 = packet[packet.startIndex + ptsOffset]
        let p1 = packet[packet.startIndex + ptsOffset + 1]
        let p2 = packet[packet.startIndex + ptsOffset + 2]
        let p3 = packet[packet.startIndex + ptsOffset + 3]
        let p4 = packet[packet.startIndex + ptsOffset + 4]

        let pts: UInt64 =
            (UInt64(p0 & 0x0E) << 29) |
            (UInt64(p1) << 22) |
            (UInt64(p2 & 0xFE) << 14) |
            (UInt64(p3) << 7) |
            (UInt64(p4 & 0xFE) >> 1)

        return TimeInterval(pts) / 90_000.0
    }
}

public enum TranscodeServerError: Error, CustomStringConvertible {
    case socketCreationFailed
    case bindFailed(Int)
    case listenFailed

    public var description: String {
        switch self {
        case .socketCreationFailed:
            return "Failed to create socket"
        case .bindFailed(let port):
            return "Failed to bind to port \(port)"
        case .listenFailed:
            return "Failed to listen on socket"
        }
    }
}
