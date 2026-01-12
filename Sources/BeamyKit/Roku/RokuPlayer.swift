import Foundation

public final class RokuPlayer: Sendable {
    private let device: RokuDevice
    private let session = URLSession.shared

    /// Web Video Caster Receiver channel ID (from Roku Channel Store)
    private static let webVideoCasterChannelID = "259656"

    public init(device: RokuDevice) {
        self.device = device
    }

    /// Check if the Roku is in Limited mode (blocking ECP commands)
    public func checkLimitedMode() async -> Bool {
        let queryURL = URL(string: "\(device.baseURL)/query/apps")!

        var request = URLRequest(url: queryURL)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            if let response = String(data: data, encoding: .utf8) {
                return response.contains("Limited mode") || response.contains("not allowed")
            }
        } catch {
            // Connection error - might still be limited mode
        }
        return false
    }

    /// Check if Web Video Caster Receiver is installed
    public func checkWebVideoCasterInstalled() async -> Bool {
        let queryURL = URL(string: "\(device.baseURL)/query/apps")!

        var request = URLRequest(url: queryURL)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await session.data(for: request)
            if let response = String(data: data, encoding: .utf8) {
                return response.contains("id=\"\(Self.webVideoCasterChannelID)\"")
            }
        } catch {
            // Connection error
        }
        return false
    }

    /// Launch the Web Video Caster Receiver channel
    public func launchReceiver() async throws {
        let launchURL = URL(string: "\(device.baseURL)/launch/\(Self.webVideoCasterChannelID)")!

        var request = URLRequest(url: launchURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            throw RokuError.castFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Give the channel time to launch
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
    }

    /// Cast a video URL to the Roku device using Web Video Caster Receiver
    /// Protocol reverse-engineered from Web Video Caster Android app
    public func cast(url: URL, name: String = "Video") async throws {
        // First check if Roku is in Limited mode
        if await checkLimitedMode() {
            throw RokuError.limitedMode
        }

        // Check if Web Video Caster Receiver is installed
        if !(await checkWebVideoCasterInstalled()) {
            throw RokuError.webVideoCasterNotInstalled
        }

        // Launch the receiver first
        try await launchReceiver()

        // Determine format from URL
        let format: String
        let urlString = url.absoluteString.lowercased()
        if urlString.contains(".m3u8") || urlString.contains("m3u") {
            format = "hls"
        } else if urlString.contains(".mp4") {
            format = "mp4"
        } else if urlString.contains(".mkv") {
            format = "mkv"
        } else {
            format = "hls" // Default to HLS for streaming
        }

        // URL-encode parameters (must encode all special chars including : and /)
        let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name

        // Use Web Video Caster protocol: cmd=play with url, title, media type, format
        let castURL = URL(string: "\(device.baseURL)/input/\(Self.webVideoCasterChannelID)?cmd=play&url=\(encodedURL)&tit=\(encodedName)&media=video&fmt=\(format)&pos=0&sub=false")!

        print("[RokuPlayer] Casting via Web Video Caster: \(castURL.absoluteString)")

        var request = URLRequest(url: castURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RokuError.invalidResponse
        }

        print("[RokuPlayer] Response status: \(httpResponse.statusCode)")
        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
            print("[RokuPlayer] Response body: \(body)")
        }

        // Check for Limited mode in response body
        if let body = String(data: data, encoding: .utf8),
           body.contains("Limited mode") || body.contains("not allowed") {
            throw RokuError.limitedMode
        }

        // 200 = success, 204 = success (no content)
        if httpResponse.statusCode != 200 && httpResponse.statusCode != 204 {
            // 403/404 often means Limited mode
            if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
                if await checkLimitedMode() {
                    throw RokuError.limitedMode
                }
            }
            throw RokuError.castFailed(statusCode: httpResponse.statusCode)
        }

        print("[RokuPlayer] Cast successful (status: \(httpResponse.statusCode))")
    }

    /// Recast a video URL without relaunching the receiver (for seeking)
    public func recast(url: URL, name: String = "Video") async throws {
        // Determine format from URL
        let format: String
        let urlString = url.absoluteString.lowercased()
        if urlString.contains(".m3u8") || urlString.contains("m3u") {
            format = "hls"
        } else if urlString.contains(".mp4") {
            format = "mp4"
        } else if urlString.contains(".mkv") {
            format = "mkv"
        } else {
            format = "hls"
        }

        let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name

        let castURL = URL(string: "\(device.baseURL)/input/\(Self.webVideoCasterChannelID)?cmd=play&url=\(encodedURL)&tit=\(encodedName)&media=video&fmt=\(format)&pos=0&sub=false")!

        print("[RokuPlayer] Recasting (seek): \(castURL.absoluteString)")

        var request = URLRequest(url: castURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            throw RokuError.castFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        print("[RokuPlayer] Recast successful")
    }

    /// Send a keypress to the Roku
    public func sendKey(_ key: RokuKey) async throws {
        let keyURL = URL(string: "\(device.baseURL)/keypress/\(key.rawValue)")!

        var request = URLRequest(url: keyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RokuError.keyPressFailed
        }

        print("[RokuPlayer] Key sent: \(key.rawValue)")
    }

    /// Toggle play/pause
    public func playPause() async throws {
        try await sendKey(.play)
    }

    /// Fast forward
    public func fastForward() async throws {
        try await sendKey(.fwd)
    }

    /// Rewind
    public func rewind() async throws {
        try await sendKey(.rev)
    }

    /// Stop playback and go back
    public func stop() async throws {
        try await sendKey(.back)
    }

    /// Go to home screen
    public func home() async throws {
        try await sendKey(.home)
    }
}

public enum RokuKey: String {
    case play = "Play"
    case fwd = "Fwd"
    case rev = "Rev"
    case back = "Back"
    case home = "Home"
    case select = "Select"
    case left = "Left"
    case right = "Right"
    case up = "Up"
    case down = "Down"
}

public enum RokuError: Error, LocalizedError {
    case invalidResponse
    case castFailed(statusCode: Int)
    case keyPressFailed
    case deviceNotFound
    case limitedMode
    case mediaPlayerNotInstalled
    case webVideoCasterNotInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Roku"
        case .castFailed(let code):
            return "Roku cast failed with status \(code)"
        case .keyPressFailed:
            return "Failed to send key to Roku"
        case .deviceNotFound:
            return "Roku device not found"
        case .limitedMode:
            return "Roku is in Limited Mode. Go to Settings → System → Advanced system settings → Control by mobile apps → Set to 'Enabled'"
        case .mediaPlayerNotInstalled:
            return "Roku Media Player not installed. Go to Channel Store → Search 'Roku Media Player' → Install"
        case .webVideoCasterNotInstalled:
            return "Web Video Caster Receiver not installed. Go to Roku Channel Store → Find 'Web Video Caster' → Install the Receiver app"
        }
    }
}
