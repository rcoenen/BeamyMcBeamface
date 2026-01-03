import Foundation

/// A simple HTTP server that serves a static file
public final class StaticFileServer: @unchecked Sendable {
    private let fileURL: URL
    private let port: Int
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let fileData: Data
    private let mimeType: String

    public var url: URL {
        URL(string: "http://\(getLocalIPAddress()):\(port)/\(fileURL.lastPathComponent)")!
    }

    public init(file: URL, port: Int) throws {
        self.fileURL = file
        self.port = port

        // Read file data upfront
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw StaticFileServerError.fileNotFound(file.path)
        }
        self.fileData = try Data(contentsOf: file)

        // Determine MIME type from extension
        self.mimeType = Self.mimeType(for: file.pathExtension)

        try startServer()
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "mp4":
            return "video/mp4"
        case "webm":
            return "video/webm"
        default:
            return "application/octet-stream"
        }
    }

    private func startServer() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw StaticFileServerError.socketCreationFailed
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
            throw StaticFileServerError.bindFailed(port)
        }

        guard listen(serverSocket, 5) >= 0 else {
            close(serverSocket)
            throw StaticFileServerError.listenFailed
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

        // Read HTTP request (consume it)
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(clientSocket, &buffer, buffer.count, 0)

        // Send HTTP headers with Content-Length
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: \(mimeType)\r
        Content-Length: \(fileData.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        _ = headers.withCString { send(clientSocket, $0, strlen($0), 0) }

        // Send file data
        fileData.withUnsafeBytes { ptr in
            _ = send(clientSocket, ptr.baseAddress, fileData.count, 0)
        }
    }

    public func stop() {
        isRunning = false
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

public enum StaticFileServerError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case socketCreationFailed
    case bindFailed(Int)
    case listenFailed

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .socketCreationFailed:
            return "Failed to create socket"
        case .bindFailed(let port):
            return "Failed to bind to port \(port)"
        case .listenFailed:
            return "Failed to listen on socket"
        }
    }
}
