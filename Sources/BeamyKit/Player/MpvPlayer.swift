import Foundation

public protocol MpvControlling: AnyObject {
    func getPosition() throws -> TimeInterval
    func getDuration() throws -> TimeInterval
    func isPaused() throws -> Bool
    func pause() throws
    func resume() throws
    func seek(to time: TimeInterval) throws
    func reloadStream(_ url: URL) throws
}

extension MpvController: MpvControlling {}

/// Player implementation that wraps MpvController and coordinates with the TranscodeServer stream.
/// mpv reports playback-time relative to its current stream; this adapter tracks the last seek target
/// and returns `seekTarget + playback-time` so the TUI always shows wall-clock position.
public final class MpvPlayer: Player {
    private let controller: MpvControlling
    private let server: ServerControlling
    private let streamURL: URL

    /// Tracks the last absolute seek target to offset mpv's relative playback-time.
    private var lastSeekTarget: TimeInterval = 0
    private var lastKnownPaused: Bool
    private var lastDevicePosition: TimeInterval = 0
    private var lastPositionUpdate: Date = Date()

    public init(controller: MpvControlling, server: ServerControlling, streamURL: URL) {
        self.controller = controller
        self.server = server
        self.streamURL = streamURL
        self.lastKnownPaused = (try? controller.isPaused()) ?? false
    }

    public func getPosition() throws -> TimeInterval {
        let playbackTime = try controller.getPosition()
        lastDevicePosition = playbackTime
        lastPositionUpdate = Date()
        return lastSeekTarget + playbackTime
    }

    public func getDuration() throws -> TimeInterval {
        try controller.getDuration()
    }

    public func isPaused() throws -> Bool {
        if let paused = try? controller.isPaused() {
            lastKnownPaused = paused
            return paused
        }
        return lastKnownPaused
    }

    public func pause() throws {
        // Pause mpv immediately, then pause transcoder to stop buffer growth.
        try controller.pause()
        server.pause()
        lastKnownPaused = true
    }

    public func resume() throws {
        // Resume transcoder first to provide data, then mpv playback.
        server.resume()
        try controller.resume()
        lastKnownPaused = false
    }

    public func seek(to time: TimeInterval) throws {
        // Preserve intended pause state across seek.
        let wasPaused = (try? controller.isPaused()) ?? lastKnownPaused
        lastSeekTarget = time
        lastDevicePosition = 0
        lastPositionUpdate = Date()

        // Restart transcoder stream at target position and reload mpv.
        server.seek(to: time, awaitClientReconnect: true)
        try controller.reloadStream(streamURL)

        // Restore pause state if needed.
        if wasPaused {
            server.pause()
            try? controller.pause()
            lastKnownPaused = true
        } else {
            server.resume()
            lastKnownPaused = false
        }
    }

    public func reload(url: URL) throws {
        let wasPaused = (try? controller.isPaused()) ?? lastKnownPaused
        lastSeekTarget = 0
        lastDevicePosition = 0
        lastPositionUpdate = Date()
        try controller.reloadStream(url)
        if wasPaused {
            server.pause()
            try? controller.pause()
            lastKnownPaused = true
        } else {
            server.resume()
            lastKnownPaused = false
        }
    }

    /// Returns an extrapolated position using the last device report and elapsed wall time.
    /// Callers may use this to smooth UI between mpv position polls.
    public func extrapolatedPosition(now: Date = Date()) -> TimeInterval {
        let elapsed = now.timeIntervalSince(lastPositionUpdate)
        return lastSeekTarget + lastDevicePosition + max(0, elapsed)
    }
}
