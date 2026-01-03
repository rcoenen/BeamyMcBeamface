import Foundation

enum ChromecastDiscovery {
    /// Discover Chromecast devices on the local network using mDNS
    static func discover(timeout: Double = 5.0) throws -> [ChromecastDevice] {
        let browser = MDNSBrowser()
        return browser.discover(timeout: timeout)
    }

    /// Find a specific device by name or IP
    static func findDevice(named nameOrIP: String, timeout: Double = 5.0) throws -> ChromecastDevice? {
        // First check if it's an IP address
        if isIPAddress(nameOrIP) {
            // Try to connect directly
            return ChromecastDevice(
                name: nameOrIP,
                address: nameOrIP,
                port: 8009,
                id: nameOrIP,
                model: nil
            )
        }

        // Otherwise search by name
        let devices = try discover(timeout: timeout)
        return devices.first { device in
            device.name.localizedCaseInsensitiveContains(nameOrIP)
        }
    }

    private static func isIPAddress(_ string: String) -> Bool {
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        return string.withCString { ptr in
            inet_pton(AF_INET, ptr, &sin.sin_addr) == 1 ||
            inet_pton(AF_INET6, ptr, &sin6.sin6_addr) == 1
        }
    }
}

/// mDNS Browser for discovering Chromecast devices
private final class MDNSBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var devices: [ChromecastDevice] = []
    private let lock = NSLock()
    private var semaphore: DispatchSemaphore?
    private var resolvedCount = 0
    private var expectedCount = 0

    func discover(timeout: Double) -> [ChromecastDevice] {
        devices = []
        services = []
        resolvedCount = 0
        expectedCount = 0
        semaphore = DispatchSemaphore(value: 0)

        browser.delegate = self
        browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")

        // Wait for discovery with timeout
        _ = semaphore?.wait(timeout: .now() + timeout)

        browser.stop()

        // Give a moment for any pending resolutions
        if expectedCount > 0 && resolvedCount < expectedCount {
            Thread.sleep(forTimeInterval: 0.5)
        }

        return devices
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        expectedCount += 1
        service.delegate = self
        service.resolve(withTimeout: 5.0)

        if !moreComing {
            // All services found, wait a bit for resolution
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.semaphore?.signal()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        semaphore?.signal()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        // Search stopped
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolvedCount += 1

        guard let addresses = sender.addresses, !addresses.isEmpty else { return }

        // Extract IP address
        var hostname: String?
        for addressData in addresses {
            addressData.withUnsafeBytes { ptr in
                let sockaddr = ptr.load(as: sockaddr.self)
                if sockaddr.sa_family == UInt8(AF_INET) {
                    var addr = ptr.load(as: sockaddr_in.self)
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if let result = inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) {
                        hostname = String(cString: result)
                    }
                }
            }
            if hostname != nil { break }
        }

        guard let address = hostname else { return }

        // Extract TXT record data
        let txtData = sender.txtRecordData()
        var model: String?
        var id: String?
        var friendlyName: String?

        if let data = txtData {
            let dict = NetService.dictionary(fromTXTRecord: data)
            model = dict["md"].flatMap { String(data: $0, encoding: .utf8) }
            id = dict["id"].flatMap { String(data: $0, encoding: .utf8) }
            friendlyName = dict["fn"].flatMap { String(data: $0, encoding: .utf8) }
        }

        let device = ChromecastDevice(
            name: friendlyName ?? sender.name,
            address: address,
            port: sender.port,
            id: id ?? sender.name,
            model: model
        )

        lock.lock()
        devices.append(device)
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvedCount += 1
    }
}
