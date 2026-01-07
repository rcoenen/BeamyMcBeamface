import Darwin
import Foundation

/// A simple HTTP server that serves a static promo image for Chromecast idle screen
public final class PromoImageServer: @unchecked Sendable {
    private let port: Int
    private let imageData: Data
    private var serverSocket: Int32 = -1
    private var isRunning = false

    public var url: URL {
        URL(string: "http://\(getLocalIPAddress()):\(port)/promo.jpg")!
    }

    public init(imagePath: String, port: Int = 8081) throws {
        self.port = port

        // Load the promo image
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
            throw PromoImageServerError.imageLoadFailed
        }
        self.imageData = data

        signal(SIGPIPE, SIG_IGN)
        try startServer()
    }

    private func startServer() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw PromoImageServerError.socketCreationFailed
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
            throw PromoImageServerError.bindFailed(port)
        }

        guard listen(serverSocket, 16) >= 0 else {
            close(serverSocket)
            throw PromoImageServerError.listenFailed
        }

        isRunning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
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

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleRequest(socket: newClientSocket)
            }
        }
    }

    private func handleRequest(socket: Int32) {
        defer {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }

        // Read request (we don't care what it is, always serve the image)
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(socket, &buffer, buffer.count, 0)

        // Send HTTP response with the promo image
        let headers = [
            "Content-Type": "image/jpeg",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "public, max-age=3600",
            "Connection": "close",
            "Content-Length": "\(imageData.count)"
        ]

        sendResponse(socket: socket, status: "200 OK", headers: headers, body: imageData)
    }

    private func sendResponse(socket: Int32, status: String, headers: [String: String], body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        guard let headerData = response.data(using: .utf8) else { return }

        _ = headerData.withUnsafeBytes { ptr in
            send(socket, ptr.baseAddress, headerData.count, 0)
        }

        _ = body.withUnsafeBytes { ptr in
            send(socket, ptr.baseAddress, body.count, 0)
        }
    }

    public func stop() {
        isRunning = false
        if serverSocket >= 0 {
            shutdown(serverSocket, SHUT_RDWR)
            close(serverSocket)
            serverSocket = -1
        }
    }

    deinit {
        stop()
    }
}

enum PromoImageServerError: Error {
    case imageLoadFailed
    case socketCreationFailed
    case bindFailed(Int)
    case listenFailed
}

// Helper to get local IP (reuse from TranscodeServer)
private func getLocalIPAddress() -> String {
    var address: String = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
        return address
    }

    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        let addr = ptr.pointee.ifa_addr.pointee

        guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
              addr.sa_family == UInt8(AF_INET) else {
            continue
        }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                      &hostname, socklen_t(hostname.count),
                      nil, 0, NI_NUMERICHOST) == 0 {
            address = String(cString: hostname)
            break
        }
    }

    return address
}
