import Foundation

public class Caster: @unchecked Sendable {
    private let device: ChromecastDevice
    private let verbose: Bool
    private var transcodeServer: TranscodeServer?

    /// Callback for progress updates (current time in seconds)
    public var onProgress: ((TimeInterval) -> Void)?

    public init(device: ChromecastDevice, verbose: Bool = false) {
        self.device = device
        self.verbose = verbose
    }

    public func cast(file: URL, mediaInfo: MediaInfo) throws {
        // Ignore SIGPIPE - we handle broken pipes via send() return values
        signal(SIGPIPE, SIG_IGN)

        // Start local transcode server
        let port = findAvailablePort()

        if verbose {
            print("Starting transcode server on port \(port)...")
        }

        transcodeServer = try FFmpeg.startStreamingTranscode(
            input: file,
            port: port,
            mediaInfo: mediaInfo
        )

        // Forward progress updates
        transcodeServer?.onProgress = { [weak self] time in
            self?.onProgress?(time)
        }

        let streamURL = transcodeServer!.url

        if verbose {
            print("Stream URL: \(streamURL)")
        }

        // Connect to Chromecast using Cast v2 protocol
        print("Connecting to \(device.name)...")

        let client = CastV2Client(device: device, verbose: verbose)
        try client.connect()

        if verbose {
            print("Connected, launching Default Media Receiver...")
        }

        try client.launchDefaultMediaReceiver()

        // Determine content type
        let contentType = "video/mp4"
        let title = file.deletingPathExtension().lastPathComponent

        if verbose {
            print("Loading media: \(title)")
        }

        // Use isLive=true for transcoded streams (no Content-Length, chunked encoding)
        try client.loadMedia(url: streamURL, contentType: contentType, title: title, isLive: true)

        print("Now playing on \(device.name)")
        print("Press Ctrl+C to stop")
        fflush(stdout)

        // Handle signals for cleanup
        signal(SIGINT) { _ in
            print("\nStopping...")
            Darwin.exit(0)
        }

        // Keep running using RunLoop instead of dispatchMain
        while true {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1.0))
        }
    }

    deinit {
        transcodeServer?.stop()
    }

    private func findAvailablePort() -> Int {
        let config = (try? Config.load().server) ?? .default
        let range = config.portRangeStart..<config.portRangeEnd

        for port in range {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { continue }
            defer { close(socket) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if result == 0 {
                return port
            }
        }
        return config.portRangeStart
    }
}

/// Handles the Cast protocol connection to a Chromecast device
public class CastConnection {
    private let device: ChromecastDevice

    public init(device: ChromecastDevice) {
        self.device = device
    }

    public func connect() throws {
        // For now, use a simpler approach via the REST API
        // The full Cast protocol requires TLS + Protobuf which is complex

        // Check if device is reachable
        let url = URL(string: "http://\(device.address):8008/apps")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var connectionError: Error?

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                connectionError = error
            }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 10)

        if let error = connectionError {
            throw CastError.connectionFailed(error.localizedDescription)
        }
    }

    public func launchMedia(url: URL) throws {
        // Launch the default media receiver app
        let launchURL = URL(string: "http://\(device.address):8008/apps/CC1AD845")!
        var request = URLRequest(url: launchURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                launchError = error
            }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 15)

        if let error = launchError {
            throw CastError.launchFailed(error.localizedDescription)
        }

        // Give the app time to start
        Thread.sleep(forTimeInterval: 2)

        // Load media via DIAL
        try loadMediaViaDIAL(url: url)
    }

    private func loadMediaViaDIAL(url: URL) throws {
        // Use the YouTube-style DIAL protocol to load media
        let dialURL = URL(string: "http://\(device.address):8008/apps/CC1AD845")!
        var request = URLRequest(url: dialURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = "v=\(url.absoluteString)".data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var loadError: Error?

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                loadError = error
            }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 10)

        if let error = loadError {
            throw CastError.mediaLoadFailed(error.localizedDescription)
        }
    }

    public func stop() {
        // Stop playback
        let stopURL = URL(string: "http://\(device.address):8008/apps/CC1AD845")!
        var request = URLRequest(url: stopURL, timeoutInterval: 5)
        request.httpMethod = "DELETE"

        let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
        task.resume()
    }
}

public enum CastError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case launchFailed(String)
    case mediaLoadFailed(String)

    public var description: String {
        switch self {
        case .connectionFailed(let msg):
            return "Failed to connect to device: \(msg)"
        case .launchFailed(let msg):
            return "Failed to launch media app: \(msg)"
        case .mediaLoadFailed(let msg):
            return "Failed to load media: \(msg)"
        }
    }
}
