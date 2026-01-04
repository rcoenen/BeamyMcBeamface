import Foundation

/// Playback state reported by Chromecast media sessions.
public enum PlayerState: String {
    case playing = "PLAYING"
    case paused = "PAUSED"
    case buffering = "BUFFERING"
    case idle = "IDLE"
}

/// Parsed MEDIA_STATUS details exposed by CastV2Client.
public struct MediaStatus {
    public let currentTime: TimeInterval
    public let playerState: PlayerState
    public let duration: TimeInterval
    public let mediaSessionId: Int

    public init?(dictionary: [String: Any]) {
        guard let sessionIdValue = (dictionary["mediaSessionId"] as? NSNumber)?.intValue else {
            return nil
        }

        guard let playerStateString = (dictionary["playerState"] as? String)?.uppercased(),
              let parsedState = PlayerState(rawValue: playerStateString) else {
            return nil
        }

        let currentTime = (dictionary["currentTime"] as? NSNumber)?.doubleValue ?? 0
        let duration = (dictionary["duration"] as? NSNumber)?.doubleValue ?? 0

        self.currentTime = currentTime
        self.playerState = parsedState
        self.duration = duration
        self.mediaSessionId = sessionIdValue
    }
}
