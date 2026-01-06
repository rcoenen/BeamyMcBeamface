import Foundation

public enum ChromecastDiscovery {
    /// Discover Chromecast devices on the local network using mDNS
    public static func discover(timeout: Double = 5.0) throws -> [ChromecastDevice] {
        let browser = MDNSBrowser()
        return browser.discover(timeout: timeout)
    }

    /// Find a specific device by name or IP
    public static func findDevice(named nameOrIP: String, timeout: Double = 5.0) throws -> ChromecastDevice? {
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
    private var resolvedCount = 0
    private var expectedCount = 0
    private var isSearching = true
    private let resolveTimeout: Double = 3.0

    func discover(timeout: Double) -> [ChromecastDevice] {
        devices = []
        services = []
        resolvedCount = 0
        expectedCount = 0
        isSearching = true

        browser.delegate = self
        browser.schedule(in: .current, forMode: .default)
        browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")

        // Run the RunLoop until timeout or discovery complete
        let deadline = Date(timeIntervalSinceNow: timeout)
        while isSearching && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        // Wait for pending resolutions (up to 2 more seconds)
        let resolutionDeadline = Date(timeIntervalSinceNow: 2.0)
        while resolvedCount < expectedCount && Date() < resolutionDeadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        browser.stop()
        browser.remove(from: .current, forMode: .default)

        return devices
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        lock.lock()
        services.append(service)
        expectedCount += 1
        lock.unlock()

        service.delegate = self
        service.resolve(withTimeout: 5.0)

        if !moreComing {
            isSearching = false
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isSearching = false
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isSearching = false
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        lock.lock()
        resolvedCount += 1
        lock.unlock()

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
            model: model,
            resolvedCastType: resolveCastType(address: address, port: sender.port, timeout: resolveTimeout)
        )

        lock.lock()
        devices.append(device)
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.lock()
        resolvedCount += 1
        lock.unlock()
    }

    /// Mirrors PyChromecast's cast_type classification:
    /// - If port != 8009 ⇒ group
    /// - Otherwise call /setup/eureka_info?params=device_info,name (https 8443, fallback http 8008)
    ///   and treat capabilities.display_supported == false as audio, else chromecast.
    private func resolveCastType(address: String, port: Int, timeout: Double) -> CastType? {
        if port != 8009 {
            return .group
        }
        let schemesAndPorts: [(String, Int)] = [("https", 8443), ("http", 8008)]
        for (scheme, servicePort) in schemesAndPorts {
            guard let url = URL(string: "\(scheme)://\(address):\(servicePort)/setup/eureka_info?params=device_info,name") else {
                continue
            }
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deviceInfo = json["device_info"] as? [String: Any],
               let capabilities = deviceInfo["capabilities"] as? [String: Any],
               let displaySupported = capabilities["display_supported"] as? Bool {
                return displaySupported ? .video : .audio
            }
        }
        return nil
    }
}
