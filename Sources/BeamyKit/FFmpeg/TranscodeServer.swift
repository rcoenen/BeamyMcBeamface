import Darwin
import Foundation

/// A simple HTTP server that runs FFmpeg to produce an HLS stream and serves the playlist/segments.
/// The same stream URL is intended for both embedded AVPlayer and Chromecast.
public final class TranscodeServer: @unchecked Sendable {
    private let input: URL
    private let port: Int
    private let mediaInfo: MediaInfo
    private let hlsDirectory: URL
    private let playlistFilename = "stream.m3u8"

    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var ffmpegProcess: Process?
    private var currentSeekPosition: TimeInterval = 0
    private let ioQueue = DispatchQueue(label: "com.beamy.transcoder.io", qos: .userInitiated)

    /// Current pause state (based on FFmpeg process signals)
    public private(set) var isPaused: Bool = false

    /// Current playback position derived from FFmpeg progress output.
    public private(set) var currentPosition: TimeInterval = 0

    /// Callback for state changes (isPaused, currentPosition)
    public var onStateChanged: ((_ isPaused: Bool, _ position: TimeInterval) -> Void)?

    /// Callback for FFmpeg process state changes
    public var onFFmpegStateChanged: ((_ isRunning: Bool) -> Void)?

    /// Callback for progress updates
    public var onProgress: (@Sendable (TimeInterval) -> Void)?

    /// HLS playlist URL to load in players.
    public var url: URL {
        URL(string: "http://\(getLocalIPAddress()):\(port)/\(playlistFilename)")!
    }

    public init(input: URL, port: Int, mediaInfo: MediaInfo) throws {
        self.input = input
        self.port = port
        self.mediaInfo = mediaInfo
        self.hlsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("beamy-hls-\(UUID().uuidString)", isDirectory: true)
        signal(SIGPIPE, SIG_IGN)
        try startServer()
        startFFmpeg(at: 0)
    }

    // MARK: - Server Lifecycle

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

        guard listen(serverSocket, 16) >= 0 else {
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

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleRequest(socket: newClientSocket)
            }
        }
    }

    private func handleRequest(socket: Int32) {
        defer {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }

        // Read HTTP request
        var buffer = [UInt8](repeating: 0, count: 4096)
        let readBytes = recv(socket, &buffer, buffer.count, 0)
        guard readBytes > 0 else { return }

        guard let request = String(bytes: buffer.prefix(readBytes), encoding: .utf8) else { return }
        guard let firstLine = request.split(whereSeparator: \.isNewline).first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        var path = String(parts[1])
        if path == "/" { path = "/\(playlistFilename)" }

        // Basic path sanitization
        if path.contains("..") {
            sendResponse(socket: socket, status: "400 Bad Request", headers: [:], body: Data())
            return
        }

        let relativePath = path.drop(while: { $0 == "/" })
        let fileURL = hlsDirectory.appendingPathComponent(String(relativePath))
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            sendResponse(socket: socket, status: "404 Not Found", headers: [:], body: Data())
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            sendResponse(socket: socket, status: "500 Internal Server Error", headers: [:], body: Data())
            return
        }

        let contentType: String
        switch fileURL.pathExtension.lowercased() {
        case "m3u8":
            contentType = "application/vnd.apple.mpegurl"
        case "ts":
            contentType = "video/mp2t"
        case "mp4":
            contentType = "video/mp4"
        default:
            contentType = "application/octet-stream"
        }

        sendResponse(
            socket: socket,
            status: "200 OK",
            headers: [
                "Content-Type": contentType,
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache",
                "Connection": "close",
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }

    private func sendResponse(socket: Int32, status: String, headers: [String: String], body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        headers.forEach { key, value in
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        _ = response.withCString { send(socket, $0, strlen($0), 0) }
        if !body.isEmpty {
            body.withUnsafeBytes { ptr in
                _ = send(socket, ptr.baseAddress, body.count, 0)
            }
        }
    }

    // MARK: - FFmpeg Management

    /// Start FFmpeg at the given position and write HLS output to disk.
    private func startFFmpeg(at position: TimeInterval) {
        ioQueue.async { [weak self] in
            guard let self else { return }

            // Kill any existing process
            if let process = ffmpegProcess, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                ffmpegProcess = nil
                notifyFFmpegStateChange(false)
            }

            // Reset state
            currentSeekPosition = position
            currentPosition = position
            onStateChanged?(isPaused, currentPosition)

            // Prepare HLS directory
            try? FileManager.default.removeItem(at: hlsDirectory)
            try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)

            let playlistPath = hlsDirectory.appendingPathComponent(playlistFilename).path
            let segmentPath = hlsDirectory.appendingPathComponent("segment%05d.ts").path

            let config = (try? Config.load().ffmpeg) ?? .default
            let ffmpeg = Process()
            ffmpeg.executableURL = URL(fileURLWithPath: config.ffmpegPath)

            var args: [String] = ["-y"]

            // Seek position (before input for fast seek)
            if position > 0 {
                args += ["-ss", String(format: "%.3f", position)]
            }

            // Input file
            args += ["-i", input.path]

            // Progress output to stderr (parsed for position feedback)
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
                "-g", "30",
                "-keyint_min", "30",
                "-sc_threshold", "0",
            ]

            // Audio settings
            args += [
                "-c:a", "aac",
                "-ac", "2",
                "-ar", "44100",
                "-b:a", config.audioBitrate,
            ]

            // HLS output
            args += [
                "-force_key_frames", "expr:gte(t,n_forced*2)",
                "-hls_time", "2",
                "-hls_list_size", "6",
                "-hls_flags", "delete_segments+append_list+omit_endlist+program_date_time",
                "-hls_segment_filename", segmentPath,
                playlistPath
            ]

            ffmpeg.arguments = args

            // Progress parser
            let stderrPipe = Pipe()
            ffmpeg.standardError = stderrPipe
            ffmpeg.standardOutput = FileHandle.nullDevice
            ffmpeg.standardInput = FileHandle.nullDevice

            let stderrHandle = stderrPipe.fileHandleForReading
            Thread.detachNewThread { [weak self] in
                self?.parseProgress(from: stderrHandle)
            }

            do {
                try ffmpeg.run()
                self.ffmpegProcess = ffmpeg
                self.isPaused = false
                self.notifyFFmpegStateChange(true)
            } catch {
                self.notifyFFmpegStateChange(false)
            }
        }
    }

    private func parseProgress(from handle: FileHandle) {
        var buffer = Data()
        while isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let range = buffer.range(of: Data([0x0A])) { // newline
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                if let line = String(data: lineData, encoding: .utf8) {
                    handleProgressLine(line)
                }
            }
        }
    }

    private func handleProgressLine(_ line: String) {
        if line.hasPrefix("out_time_ms=") {
            let value = line.replacingOccurrences(of: "out_time_ms=", with: "")
            if let ms = Double(value) {
                let seconds = ms / 1_000_000.0
                currentPosition = seconds
                onProgress?(seconds)
                onStateChanged?(isPaused, seconds)
            }
        }
    }

    private func notifyFFmpegStateChange(_ isRunning: Bool) {
        onFFmpegStateChanged?(isRunning)
    }

    // MARK: - Playback Control

    public func stop() {
        isRunning = false
        if let process = ffmpegProcess, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        ffmpegProcess = nil
        notifyFFmpegStateChange(false)
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        try? FileManager.default.removeItem(at: hlsDirectory)
    }

    public func pause() {
        guard !isPaused, let process = ffmpegProcess, process.isRunning else { return }
        isPaused = true
        kill(process.processIdentifier, SIGSTOP)
        onStateChanged?(isPaused, currentPosition)
    }

    public func resume() {
        guard isPaused, let process = ffmpegProcess, process.isRunning else { return }
        isPaused = false
        kill(process.processIdentifier, SIGCONT)
        onStateChanged?(isPaused, currentPosition)
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
    public func seek(to time: TimeInterval) {
        seek(to: time, awaitClientReconnect: false)
    }

    public func seek(to time: TimeInterval, awaitClientReconnect: Bool) {
        // awaitClientReconnect ignored for HLS; restart immediately
        startFFmpeg(at: time)
        isPaused = false
        onStateChanged?(isPaused, currentPosition)
    }

    // MARK: - Utilities

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
