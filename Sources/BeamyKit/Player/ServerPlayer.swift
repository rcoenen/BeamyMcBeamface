import Foundation

/// Player implementation that delegates directly to TranscodeServer state and controls.
public final class ServerPlayer: Player {
    private let server: ServerControlling
    private let duration: TimeInterval

    public init(server: ServerControlling, duration: TimeInterval) {
        self.server = server
        self.duration = duration
    }

    public func getPosition() throws -> TimeInterval {
        server.currentPosition
    }

    public func getDuration() throws -> TimeInterval {
        duration
    }

    public func isPaused() throws -> Bool {
        server.isPaused
    }

    public func pause() throws {
        server.pause()
    }

    public func resume() throws {
        server.resume()
    }

    public func seek(to time: TimeInterval) throws {
        server.seek(to: time)
    }

    public func reload(url: URL) throws {
        throw PlayerError.unsupportedOperation
    }
}
