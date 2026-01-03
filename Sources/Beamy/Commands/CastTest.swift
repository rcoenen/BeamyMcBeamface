import ArgumentParser
import BeamyKit
import Foundation

struct CastTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cast-test",
        abstract: "Cast test image to verify Chromecast connectivity"
    )

    @Option(name: .shortAndLong, help: "Target device name or IP")
    var device: String?

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Double = 5.0

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() throws {
        // Find test image
        let testImagePath = findTestImage()
        guard let imagePath = testImagePath else {
            throw ValidationError("Test image not found. Expected: assets/backdrop_1920x1080.jpg")
        }

        let imageURL = URL(fileURLWithPath: imagePath)
        print("Test image: \(imageURL.lastPathComponent)")

        // Find device
        let targetDevice = try findDevice()
        print("Target device: \(targetDevice.name)")

        // Start static file server
        let port = findAvailablePort()
        if verbose {
            print("Starting server on port \(port)...")
        }

        let server = try StaticFileServer(file: imageURL, port: port)
        let streamURL = server.url

        if verbose {
            print("Image URL: \(streamURL)")
        }

        // Connect to Chromecast using Cast v2 protocol
        print("Connecting to \(targetDevice.name)...")

        let client = CastV2Client(device: targetDevice, verbose: verbose)
        try client.connect()

        if verbose {
            print("Connected, launching Default Media Receiver...")
        }

        try client.launchDefaultMediaReceiver()

        // Determine content type from file extension
        let contentType: String
        switch imageURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            contentType = "image/jpeg"
        case "png":
            contentType = "image/png"
        case "gif":
            contentType = "image/gif"
        case "webp":
            contentType = "image/webp"
        default:
            contentType = "image/jpeg"
        }

        try client.loadMedia(url: streamURL, contentType: contentType, title: "Beamy McBeamface")

        print("Displaying test image on \(targetDevice.name)")
        print("Press Ctrl+C to stop")
        fflush(stdout)

        // Handle cleanup on exit
        signal(SIGINT) { _ in
            print("\nStopping...")
            Darwin.exit(0)
        }

        // Keep running
        dispatchMain()
    }

    private func findTestImage() -> String? {
        // Try relative paths from current directory
        let candidates = [
            "assets/backdrop_1920x1080.jpg",
            "./assets/backdrop_1920x1080.jpg",
            "../assets/backdrop_1920x1080.jpg",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try executable-relative path
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let executableDir = executableURL.deletingLastPathComponent()
        let relativeToExec = executableDir.appendingPathComponent("../../assets/backdrop_1920x1080.jpg").path
        if FileManager.default.fileExists(atPath: relativeToExec) {
            return relativeToExec
        }

        return nil
    }

    private func findDevice() throws -> ChromecastDevice {
        if let deviceName = device {
            print("Looking for device: \(deviceName)...")
            guard let found = try ChromecastDiscovery.findDevice(named: deviceName, timeout: timeout) else {
                throw ValidationError("Device not found: \(deviceName)")
            }
            return found
        }

        // Check config for default device
        if let config = try? Config.load(),
           let defaultDevice = config.chromecast.defaultDevice {
            print("Using default device: \(defaultDevice)...")
            if let found = try ChromecastDiscovery.findDevice(named: defaultDevice, timeout: timeout) {
                return found
            }
            print("Default device not found, discovering...")
        }

        // Discover and use first video-capable device
        print("Discovering Chromecast devices...")
        let allDevices = try ChromecastDiscovery.discover(timeout: timeout)
        let videoDevices = allDevices.filter { $0.isVideoCapable }

        guard let first = videoDevices.first else {
            if allDevices.isEmpty {
                throw ValidationError("No Chromecast devices found on network")
            } else {
                throw ValidationError("No video-capable Chromecast devices found (found \(allDevices.count) audio-only)")
            }
        }

        return first
    }

    private func findAvailablePort() -> Int {
        let config = (try? Config.load().server) ?? .default
        let range = config.portRangeStart..<config.portRangeEnd

        for port in range {
            let testSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard testSocket >= 0 else { continue }
            defer { close(testSocket) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(testSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if result == 0 {
                return port
            }
        }
        return config.portRangeStart
    }
}
