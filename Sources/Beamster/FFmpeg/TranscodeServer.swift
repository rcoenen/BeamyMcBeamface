import Foundation

/// A simple HTTP server that serves transcoded media content
final class TranscodeServer: @unchecked Sendable {
    private let input: URL
    private let port: Int
    private let mediaInfo: MediaInfo
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var ffmpegProcess: Process?

    var url: URL {
        URL(string: "http://\(getLocalIPAddress()):\(port)/media.mp4")!
    }

    init(input: URL, port: Int, mediaInfo: MediaInfo) throws {
        self.input = input
        self.port = port
        self.mediaInfo = mediaInfo
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

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else { continue }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }
    }

    private func handleConnection(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read HTTP request (we don't really parse it, just consume it)
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(clientSocket, &buffer, buffer.count, 0)

        // Send HTTP headers
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: video/mp4\r
        Transfer-Encoding: chunked\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        _ = headers.withCString { send(clientSocket, $0, strlen($0), 0) }

        // Start FFmpeg and pipe output to client
        let config = (try? Config.load().ffmpeg) ?? .default
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: config.ffmpegPath)
        ffmpeg.arguments = [
            "-i", input.path,
            "-c:v", "libx264",
            "-preset", config.preset,
            "-tune", "zerolatency",
            "-crf", "\(config.crf)",
            "-c:a", "aac",
            "-b:a", config.audioBitrate,
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-f", "mp4",
            "pipe:1"
        ]

        let outputPipe = Pipe()
        ffmpeg.standardOutput = outputPipe
        ffmpeg.standardError = FileHandle.nullDevice

        do {
            try ffmpeg.run()
            self.ffmpegProcess = ffmpeg

            let fileHandle = outputPipe.fileHandleForReading

            while ffmpeg.isRunning || fileHandle.availableData.count > 0 {
                let data = fileHandle.availableData
                if data.isEmpty { break }

                // Send as chunked encoding
                let chunkHeader = String(format: "%X\r\n", data.count)
                _ = chunkHeader.withCString { send(clientSocket, $0, strlen($0), 0) }
                _ = data.withUnsafeBytes { send(clientSocket, $0.baseAddress, data.count, 0) }
                _ = "\r\n".withCString { send(clientSocket, $0, 2, 0) }
            }

            // Send final chunk
            _ = "0\r\n\r\n".withCString { send(clientSocket, $0, 5, 0) }

        } catch {
            // Connection closed or error
        }
    }

    func stop() {
        isRunning = false
        ffmpegProcess?.terminate()
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
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

enum TranscodeServerError: Error, CustomStringConvertible {
    case socketCreationFailed
    case bindFailed(Int)
    case listenFailed

    var description: String {
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
