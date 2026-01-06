import Foundation

/// Player implementation backed by Chromecast via CastV2Client.
public final class ChromecastPlayer: Player {
    private let statusProvider: () -> MediaStatus?
    private let commandSender: (String, Int?, [String: Any]) throws -> Void
    private let reloadHandler: (URL) throws -> Void

    public init(client: CastV2Client) {
        self.statusProvider = { client.latestMediaStatus }
        self.commandSender = { type, mediaSessionId, additional in
            try client.sendMediaCommand(type: type, mediaSessionId: mediaSessionId, additional: additional)
        }
        self.reloadHandler = { url in
            try client.loadMedia(url: url, contentType: "video/mp2t", isLive: true)
        }
    }

    // Internal initializer for testing without network I/O.
    init(
        statusProvider: @escaping () -> MediaStatus?,
        commandSender: @escaping (String, Int?, [String: Any]) throws -> Void,
        reloadHandler: @escaping (URL) throws -> Void
    ) {
        self.statusProvider = statusProvider
        self.commandSender = commandSender
        self.reloadHandler = reloadHandler
    }

    public func getPosition() throws -> TimeInterval {
        guard let status = statusProvider() else {
            throw PlayerError.statusUnavailable
        }
        return status.currentTime
    }

    public func getDuration() throws -> TimeInterval {
        guard let status = statusProvider() else {
            throw PlayerError.statusUnavailable
        }
        return status.duration
    }

    public func isPaused() throws -> Bool {
        guard let status = statusProvider() else {
            throw PlayerError.statusUnavailable
        }
        return status.playerState == .paused
    }

    public func pause() throws {
        let status = try currentStatus()
        try commandSender("PAUSE", status.mediaSessionId, [:])

        // Validate pause completed
        let validated = waitForStatusUpdate(timeout: 3.0) { updatedStatus in
            updatedStatus.playerState == .paused
        }

        if !validated {
            print("[ChromecastPlayer] Warning: Pause not confirmed within 3s")
        }
    }

    public func resume() throws {
        let status = try currentStatus()
        try commandSender("PLAY", status.mediaSessionId, [:])

        // Validate resume completed
        let validated = waitForStatusUpdate(timeout: 3.0) { updatedStatus in
            updatedStatus.playerState == .playing
        }

        if !validated {
            print("[ChromecastPlayer] Warning: Resume not confirmed within 3s")
        }
    }

    public func seek(to time: TimeInterval) throws {
        let status = try currentStatus()
        try commandSender("SEEK", status.mediaSessionId, ["currentTime": time])

        // Validate seek completed (within ±2s tolerance)
        let validated = waitForStatusUpdate(timeout: 3.0) { updatedStatus in
            abs(updatedStatus.currentTime - time) < 2.0
        }

        if !validated {
            // Log warning but don't fail - seek was sent, just not confirmed
            print("[ChromecastPlayer] Warning: Seek to \(time)s not confirmed within 3s")
        }
    }

    public func reload(url: URL) throws {
        // Reloading uses LOAD on the current media session.
        _ = try currentStatus()
        try reloadHandler(url)
    }

    private func currentStatus() throws -> MediaStatus {
        guard let status = statusProvider() else {
            throw PlayerError.statusUnavailable
        }
        return status
    }

    /// Wait for status update matching predicate, polling every 100ms up to timeout
    private func waitForStatusUpdate(timeout: TimeInterval, predicate: (MediaStatus) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let status = statusProvider(), predicate(status) {
                return true  // Validation succeeded
            }
            Thread.sleep(forTimeInterval: 0.1)  // Yield thread, poll again
        }

        return false  // Timeout
    }
}
