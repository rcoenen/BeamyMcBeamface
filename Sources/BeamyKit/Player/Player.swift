import Foundation

/// Abstraction over playback backends used by the TUI.
/// Methods return after the underlying backend accepts the command; they do not wait for playback to settle.
/// All time values are expressed in seconds.
public protocol Player {
    /// Returns the current playback position in seconds relative to the start of the active stream.
    func getPosition() throws -> TimeInterval

    /// Returns the playback duration in seconds for the active stream.
    func getDuration() throws -> TimeInterval

    /// Indicates whether playback is currently paused.
    func isPaused() throws -> Bool

    /// Requests playback pause. Returns when the command is dispatched to the backend.
    func pause() throws

    /// Requests playback resume. Returns when the command is dispatched to the backend.
    func resume() throws

    /// Requests a seek to an absolute position (seconds) within the active stream.
    func seek(to time: TimeInterval) throws

    /// Requests the backend reload the provided stream URL, if supported.
    func reload(url: URL) throws
}

/// Normalized playback errors surfaced by Player implementations.
public enum PlayerError: Error {
    /// The backend cannot provide the requested status (e.g., no media status available).
    case statusUnavailable
    /// The requested operation is not supported by the backend.
    case unsupportedOperation
    /// The backend rejected or failed to process the command; optional reason included.
    case commandFailed(String?)
    /// The backend connection or session is unavailable.
    case disconnected
}

public protocol ServerControlling: AnyObject {
    var currentPosition: TimeInterval { get }
    var isPaused: Bool { get }
    func pause()
    func resume()
    func seek(to time: TimeInterval)
    func seek(to time: TimeInterval, awaitClientReconnect: Bool)
}

extension TranscodeServer: ServerControlling {}
