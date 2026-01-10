import Foundation

public final class RokuDiscovery: @unchecked Sendable {
    public static let shared = RokuDiscovery()

    private let multicastGroup = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    private let searchTarget = "roku:ecp"

    private init() {}

    public func discover(timeout: TimeInterval = 3.0) async -> [RokuDevice] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = self.performDiscovery(timeout: timeout)
                continuation.resume(returning: devices)
            }
        }
    }

    private func performDiscovery(timeout: TimeInterval) -> [RokuDevice] {
        var devices: [String: RokuDevice] = [:]

        // Create UDP socket
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            print("[RokuDiscovery] Failed to create socket: \(errno)")
            return []
        }
        defer { close(sock) }

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var ttl: UInt8 = 4  // Increased TTL for better network reach
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // Set shorter recv timeout for faster polling
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)  // 500ms
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Build M-SEARCH message
        let message = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastGroup):\(ssdpPort)",
            "MAN: \"ssdp:discover\"",
            "ST: \(searchTarget)",
            "MX: 2",
            "",
            ""
        ].joined(separator: "\r\n")

        // Setup destination address
        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = ssdpPort.bigEndian
        inet_pton(AF_INET, multicastGroup, &destAddr.sin_addr)

        let messageData = message.data(using: .utf8)!

        // Send multiple M-SEARCH requests for reliability
        for i in 0..<3 {
            let sent = messageData.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        sendto(sock, buffer.baseAddress, buffer.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 {
                print("[RokuDiscovery] Failed to send M-SEARCH \(i+1): \(errno)")
            }
            if i < 2 {
                usleep(100_000)  // 100ms between requests
            }
        }
        print("[RokuDiscovery] Sent 3x M-SEARCH to \(multicastGroup):\(ssdpPort)")

        // Receive responses
        var buffer = [UInt8](repeating: 0, count: 2048)
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let received = recv(sock, &buffer, buffer.count, 0)
            if received > 0 {
                if let response = String(bytes: buffer[0..<received], encoding: .utf8) {
                    print("[RokuDiscovery] Got response:\n\(response)")

                    if let device = parseResponse(response) {
                        devices[device.id] = device
                        print("[RokuDiscovery] Found: \(device.name) at \(device.address)")
                    }
                }
            } else if received < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                // Timeout or error
                break
            }
        }

        print("[RokuDiscovery] Discovery complete. Found \(devices.count) device(s)")
        return Array(devices.values)
    }

    private func parseResponse(_ response: String) -> RokuDevice? {
        // Check if it's a Roku response
        guard response.lowercased().contains("roku") else { return nil }

        // Extract LOCATION header
        var location: String?
        let lines = response.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard let locationStr = location,
              let url = URL(string: locationStr),
              let host = url.host else {
            return nil
        }

        let port = url.port ?? 8060

        // Fetch device info synchronously
        return fetchDeviceInfo(host: host, port: port)
    }

    private func fetchDeviceInfo(host: String, port: Int) -> RokuDevice? {
        let deviceInfoURL = URL(string: "http://\(host):\(port)/query/device-info")!

        var request = URLRequest(url: deviceInfoURL)
        request.timeoutInterval = 2.0

        let semaphore = DispatchSemaphore(value: 0)
        var result: RokuDevice?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            guard let data = data,
                  let xml = String(data: data, encoding: .utf8) else {
                return
            }

            result = self.parseDeviceXML(xml, host: host, port: port)
        }
        task.resume()
        semaphore.wait()

        return result
    }

    private func parseDeviceXML(_ xml: String, host: String, port: Int) -> RokuDevice? {
        func extractValue(_ tag: String) -> String? {
            let pattern = "<\(tag)>([^<]*)</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range])
            }
            return nil
        }

        let name = extractValue("friendly-device-name") ?? extractValue("user-device-name") ?? "Roku"
        let serialNumber = extractValue("serial-number") ?? UUID().uuidString
        let model = extractValue("model-name") ?? "Roku"

        return RokuDevice(
            id: serialNumber,
            name: name,
            address: host,
            port: port,
            serialNumber: serialNumber,
            model: model
        )
    }
}
