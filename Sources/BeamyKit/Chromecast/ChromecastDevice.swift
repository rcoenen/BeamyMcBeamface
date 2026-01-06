import Foundation

public enum CastType: String, Sendable {
    case video = "video"
    case audio = "audio"
    case group = "group"
    case unknown = "unknown"
}

public struct ChromecastDevice: Sendable, Hashable, Equatable {
    public let name: String
    public let address: String
    public let port: Int
    public let id: String
    public let model: String?
    /// Optional, pre-resolved cast type (e.g., from /setup/eureka_info)
    public let resolvedCastType: CastType?

    public init(name: String, address: String, port: Int, id: String, model: String? = nil, resolvedCastType: CastType? = nil) {
        self.name = name
        self.address = address
        self.port = port
        self.id = id
        self.model = model
        self.resolvedCastType = resolvedCastType
    }

    /// Determines the device type based on model name and port
    public var castType: CastType {
        if let resolvedCastType {
            return resolvedCastType
        }

        // Groups use non-standard ports
        if port != 8009 {
            return .group
        }

        let modelLower = model?.lowercased()
        let nameLower = name.lowercased()

        guard let model = modelLower else {
            // Fallback to friendly name heuristics when model is missing.
            if nameLower.contains("tv") || nameLower.contains("display") || nameLower.contains("chromecast") {
                return .video
            }
            if nameLower.contains("speaker") || nameLower.contains("audio") {
                return .audio
            }
            return .unknown
        }

        // Video-capable devices (Chromecast, displays, TVs)
        let videoModels = [
            "chromecast",
            "chromecast hd",
            "chromecast ultra",
            "eureka dongle",
            "google nest hub",
            "google nest hub max",
            "lenovo smart display",
            "nvidia shield",
            "sony bravia",
            "vizio",
            "philips",
            "xiaomi",
            "mitv",
        ]

        for videoModel in videoModels {
            if model.contains(videoModel) {
                return .video
            }
        }

        // Audio-only devices (speakers, soundbars)
        let audioModels = [
            "google home",
            "nest audio",
            "nest mini",
            "nest wifi",
            "chromecast audio",
            "jbl link",
            "bose",
            "sonos",
            "marshall",
            "pioneer",
            "canton",
            "bang & olufsen",
            "harman kardon",
            "lg wk",
            "thinq speaker",
            "soundbar",
            "speaker",
        ]

        for audioModel in audioModels {
            if model.contains(audioModel) {
                return .audio
            }
        }

        // Check for common keywords
        if model.contains("tv") || model.contains("display") || model.contains("hub") {
            return .video
        }

        if model.contains("speaker") || model.contains("audio") || model.contains("sound") {
            return .audio
        }

        return .unknown
    }

    /// Returns true if the device supports video playback
    public var isVideoCapable: Bool {
        castType == .video
    }

    /// Returns true if the device is audio-only
    public var isAudioOnly: Bool {
        castType == .audio
    }

    /// Human-readable capability description
    public var capabilityDescription: String {
        switch castType {
        case .video:
            return "Video + Audio"
        case .audio:
            return "Audio Only"
        case .group:
            return "Speaker Group"
        case .unknown:
            return "Unknown"
        }
    }
}
