import Foundation

/// Player implementation backed by Chromecast via CastV2Client.
public final class ChromecastPlayer: Player {
    private let statusProvider: () -> MediaStatus?
    private let commandSender: (String, Int?, [String: Any]) throws -> Void
    private let reloadHandler: (URL) throws -> Void
    private let statusRequester: () throws -> Void
    private let timestampProvider: () -> Date?

    public init(client: CastV2Client) {
        self.statusProvider = { client.latestMediaStatus }
        self.commandSender = { type, mediaSessionId, additional in
            try client.sendMediaCommand(type: type, mediaSessionId: mediaSessionId, additional: additional)
        }
        self.reloadHandler = { url in
        try client.loadMedia(url: url, contentType: "application/vnd.apple.mpegurl", isLive: true)
    }
        self.statusRequester = {
            try client.requestMediaStatus()
        }
        self.timestampProvider = { client.statusTimestamp }
    }

    // Internal initializer for testing without network I/O.
    init(
        statusProvider: @escaping () -> MediaStatus?,
        commandSender: @escaping (String, Int?, [String: Any]) throws -> Void,
        reloadHandler: @escaping (URL) throws -> Void,
        statusRequester: @escaping () throws -> Void = {},
        timestampProvider: @escaping () -> Date? = { nil }
    ) {
        self.statusProvider = statusProvider
        self.commandSender = commandSender
        self.reloadHandler = reloadHandler
        self.statusRequester = statusRequester
        self.timestampProvider = timestampProvider
    }

    public func getPosition() throws -> TimeInterval {
        guard let status = statusProvider() else {
            throw PlayerError.statusUnavailable
        }

        // Interpolate position when playing to provide smoother updates
        if status.playerState == .playing, let timestamp = timestampProvider() {
            let elapsed = Date().timeIntervalSince(timestamp)
            let interpolated = status.currentTime + elapsed
            let duration = status.duration
            // Clamp to duration
            return min(interpolated, duration)
        }

        // No interpolation when paused or timestamp unavailable
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

        // Validate pause completed (silent - TUI drift detection will catch issues)
        _ = waitForStatusUpdate(timeout: 3.0) { updatedStatus in
            updatedStatus.playerState == .paused
        }
    }

    public func resume() throws {
        let status = try currentStatus()
        try commandSender("PLAY", status.mediaSessionId, [:])

        // Validate resume completed (silent - TUI drift detection will catch issues)
        _ = waitForStatusUpdate(timeout: 3.0) { updatedStatus in
            updatedStatus.playerState == .playing
        }
    }

    public func seek(to time: TimeInterval) throws {
        let status = try currentStatus()
        try commandSender("SEEK", status.mediaSessionId, ["currentTime": time])

        // Validate seek completed (silent - TUI drift detection will catch issues)
        // Tolerance: ±2s, timeout: 3s
        _ = waitForStatusUpdate(timeout: 3.0) { updatedStatus in
            abs(updatedStatus.currentTime - time) < 2.0
        }
    }

    public func reload(url: URL) throws {
        // Reloading uses LOAD on the current media session.
        _ = try currentStatus()
        try reloadHandler(url)
    }

    /// Request fresh position update from Chromecast.
    /// Call this periodically during playback to keep latestMediaStatus fresh.
    public func requestPositionUpdate() throws {
        try statusRequester()
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
