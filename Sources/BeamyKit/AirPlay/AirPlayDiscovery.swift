import Foundation

private func airplayLog(_ message: String) {
    let line = "[AirPlay] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/beamy-airplay.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
}

public enum AirPlayDiscovery {
    /// Discover AirPlay devices on the local network using mDNS/Bonjour
    public static func discover(timeout: Double = 5.0, videoOnly: Bool = true) -> [AirPlayDevice] {
        let browser = AirPlayBrowser()
        var devices = browser.discover(timeout: timeout)

        if videoOnly {
            devices = devices.filter { $0.isVideoCapable }
            airplayLog("After video filter: \(devices.count) devices")
        }

        return devices
    }

    /// Find a specific AirPlay device by name or IP
    public static func findDevice(named nameOrIP: String, timeout: Double = 5.0) -> AirPlayDevice? {
        if isIPAddress(nameOrIP) {
            return AirPlayDevice(
                name: nameOrIP,
                address: nameOrIP,
                port: 7000,
                deviceId: nameOrIP,
                features: [.video, .videoHTTPLive]
            )
        }

        let devices = discover(timeout: timeout, videoOnly: false)
        return devices.first { $0.name.localizedCaseInsensitiveContains(nameOrIP) }
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

// MARK: - mDNS Browser

private final class AirPlayBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var devices: [AirPlayDevice] = []
    private let lock = NSLock()
    private var resolvedCount = 0
    private var expectedCount = 0
    private var isSearching = true

    func discover(timeout: Double) -> [AirPlayDevice] {
        devices = []
        services = []
        resolvedCount = 0
        expectedCount = 0
        isSearching = true

        airplayLog("Starting NetServiceBrowser discovery, timeout: \(timeout)s, isMainThread: \(Thread.isMainThread)")

        browser.delegate = self
        browser.schedule(in: .main, forMode: .default)
        browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")

        // Run the main RunLoop until timeout or discovery complete
        let deadline = Date(timeIntervalSinceNow: timeout)
        while isSearching && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        airplayLog("Search phase done, found \(expectedCount) services, waiting for resolution...")

        // Wait for pending resolutions
        let resolutionDeadline = Date(timeIntervalSinceNow: 3.0)
        while resolvedCount < expectedCount && Date() < resolutionDeadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        browser.stop()
        browser.remove(from: .main, forMode: .default)

        airplayLog("Discovery complete: \(devices.count) devices")
        return devices
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        airplayLog("Found service: \(service.name), moreComing: \(moreComing)")

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
        airplayLog("didNotSearch error: \(errorDict)")
        isSearching = false
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        airplayLog("Browser stopped")
        isSearching = false
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        airplayLog("Resolved: \(sender.name) at port \(sender.port)")

        lock.lock()
        resolvedCount += 1
        lock.unlock()

        guard let addresses = sender.addresses, !addresses.isEmpty else {
            airplayLog("No addresses for \(sender.name)")
            return
        }

        // Extract IPv4 address
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

        guard let address = hostname else {
            airplayLog("Could not extract IP for \(sender.name)")
            return
        }

        // Parse TXT record
        var deviceId: String?
        var model: String?
        var airplayVersion: String?
        var features: AirPlayFeatures = []

        if let txtData = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            deviceId = dict["deviceid"].flatMap { String(data: $0, encoding: .utf8) }
            model = dict["model"].flatMap { String(data: $0, encoding: .utf8) }
            airplayVersion = dict["srcvers"].flatMap { String(data: $0, encoding: .utf8) }

            if let featuresData = dict["features"],
               let featuresStr = String(data: featuresData, encoding: .utf8) {
                features = parseFeatures(featuresStr)
            }
        }

        let device = AirPlayDevice(
            name: sender.name,
            address: address,
            port: sender.port > 0 ? sender.port : 7000,
            deviceId: deviceId ?? sender.name,
            model: model,
            airplayVersion: airplayVersion,
            features: features
        )

        airplayLog("Device: \(device.name) @ \(device.address):\(device.port)")
        airplayLog("  model=\(device.model ?? "nil"), features=\(features.rawValue)")
        airplayLog("  isVideoCapable=\(device.isVideoCapable), requiresPairing=\(device.requiresPairing)")

        lock.lock()
        devices.append(device)
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        airplayLog("didNotResolve \(sender.name): \(errorDict)")
        lock.lock()
        resolvedCount += 1
        lock.unlock()
    }

    // MARK: - Feature Parsing

    private func parseFeatures(_ string: String) -> AirPlayFeatures {
        let parts = string.split(separator: ",")

        if parts.count >= 2 {
            let highStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let lowStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let high = parseHex(highStr)
            let low = parseHex(lowStr)
            return AirPlayFeatures(rawValue: (high << 32) | low)
        } else {
            return AirPlayFeatures(rawValue: parseHex(string))
        }
    }

    private func parseHex(_ string: String) -> UInt64 {
        var str = string.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("0x") || str.hasPrefix("0X") {
            str = String(str.dropFirst(2))
        }
        return UInt64(str, radix: 16) ?? 0
    }
}
