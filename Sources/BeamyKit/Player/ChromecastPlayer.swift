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
    }

    public func resume() throws {
        let status = try currentStatus()
        try commandSender("PLAY", status.mediaSessionId, [:])
    }

    public func seek(to time: TimeInterval) throws {
        let status = try currentStatus()
        try commandSender("SEEK", status.mediaSessionId, ["currentTime": time])
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
}
