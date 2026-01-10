import Foundation

public final class RokuPlayer: Sendable {
    private let device: RokuDevice
    private let session = URLSession.shared

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

    /// Cast an HLS video URL to the Roku device
    public func cast(url: URL, name: String = "Video") async throws {
        // First check if Roku is in Limited mode
        if await checkLimitedMode() {
            throw RokuError.limitedMode
        }

        // Use PlayOnRoku channel (15985) with /input endpoint for video casting
        // This is the correct method per Roku ECP documentation
        // Note: Must use alphanumerics only - urlQueryAllowed doesn't encode : and / which breaks the URL
        let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name

        // Use /input/15985 endpoint (PlayOnRoku) to cast video
        let castURL = URL(string: "\(device.baseURL)/input/15985?t=v&u=\(encodedURL)&videoName=\(encodedName)&videoFormat=hls")!

        print("[RokuPlayer] Casting via PlayOnRoku: \(castURL.absoluteString)")

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
        }
    }
}
