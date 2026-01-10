import Darwin
import Foundation

/// Serves a static image as an HLS video stream using FFmpeg.
/// Useful for displaying promo images on devices that only support video (like Roku).
public final class ImageStreamServer: @unchecked Sendable {
    private let imagePath: String
    private let port: Int
    private let hlsDirectory: URL
    private let playlistFilename = "promo.m3u8"

    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var ffmpegProcess: Process?

    /// HLS playlist URL to cast to devices
    public var url: URL {
        URL(string: "http://\(getLocalIPAddress()):\(port)/\(playlistFilename)")!
    }

    public init(imagePath: String, port: Int = 8082) throws {
        self.imagePath = imagePath
        self.port = port
        self.hlsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beamy-promo-\(UUID().uuidString)", isDirectory: true)

        signal(SIGPIPE, SIG_IGN)
        try startServer()
        startFFmpeg()
    }

    private func startServer() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw ImageStreamError.socketCreationFailed
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
            throw ImageStreamError.bindFailed(port)
        }

        guard listen(serverSocket, 8) >= 0 else {
            close(serverSocket)
            throw ImageStreamError.listenFailed
        }

        isRunning = true

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
                self?.handleRequest(socket: clientSocket)
            }
        }
    }

    private func handleRequest(socket: Int32) {
        defer {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let readBytes = recv(socket, &buffer, buffer.count, 0)
        guard readBytes > 0 else { return }

        guard let request = String(bytes: buffer.prefix(readBytes), encoding: .utf8) else { return }
        guard let firstLine = request.split(whereSeparator: \.isNewline).first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        var path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        if path == "/" { path = "/\(playlistFilename)" }

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

    private func startFFmpeg() {
        try? FileManager.default.removeItem(at: hlsDirectory)
        try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)

        let playlistPath = hlsDirectory.appendingPathComponent(playlistFilename).path
        let segmentPath = hlsDirectory.appendingPathComponent("promo%03d.ts").path

        let config = (try? Config.load().ffmpeg) ?? .default
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: config.ffmpegPath)

        // Convert static image to a 60-second looping video
        // -loop 1: loop the input image
        // -t 60: duration of 60 seconds (loops on Roku)
        // -r 1: 1 fps (minimal CPU/bandwidth for static image)
        // -pix_fmt yuv420p: compatibility with Roku
        ffmpeg.arguments = [
            "-y",
            "-loop", "1",
            "-i", imagePath,
            "-c:v", "libx264",
            "-t", "60",
            "-r", "1",
            "-pix_fmt", "yuv420p",
            "-preset", "ultrafast",
            "-tune", "stillimage",
            "-b:v", "500k",
            "-hls_time", "10",
            "-hls_list_size", "0",
            "-hls_playlist_type", "vod",
            "-hls_segment_filename", segmentPath,
            playlistPath
        ]

        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice
        ffmpeg.standardInput = FileHandle.nullDevice

        do {
            print("[ImageStreamServer] Starting FFmpeg to convert image to HLS...")
            print("[ImageStreamServer] Image: \(imagePath)")
            print("[ImageStreamServer] Output: \(playlistPath)")
            try ffmpeg.run()
            self.ffmpegProcess = ffmpeg

            // Wait for FFmpeg to create initial segments
            DispatchQueue.global().async {
                ffmpeg.waitUntilExit()
                print("[ImageStreamServer] FFmpeg finished (exit: \(ffmpeg.terminationStatus))")
            }
        } catch {
            print("[ImageStreamServer] FFmpeg failed: \(error)")
        }
    }

    public func stop() {
        isRunning = false
        if let process = ffmpegProcess, process.isRunning {
            process.terminate()
        }
        ffmpegProcess = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        try? FileManager.default.removeItem(at: hlsDirectory)
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

public enum ImageStreamError: Error, CustomStringConvertible {
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
