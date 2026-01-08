import Foundation

/// AirPlay device capabilities derived from feature flags
public struct AirPlayFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // Core features (from unofficial AirPlay spec + pyatv)
    public static let video           = AirPlayFeatures(rawValue: 1 << 0)   // 0x01
    public static let photo           = AirPlayFeatures(rawValue: 1 << 1)   // 0x02
    public static let videoFairPlay   = AirPlayFeatures(rawValue: 1 << 2)   // 0x04
    public static let videoVolumeCtrl = AirPlayFeatures(rawValue: 1 << 3)   // 0x08
    public static let videoHTTPLive   = AirPlayFeatures(rawValue: 1 << 4)   // 0x10 - HLS support
    public static let slideshow       = AirPlayFeatures(rawValue: 1 << 5)   // 0x20
    public static let screen          = AirPlayFeatures(rawValue: 1 << 7)   // 0x80 - Mirroring
    public static let screenRotate    = AirPlayFeatures(rawValue: 1 << 8)   // 0x100
    public static let audio           = AirPlayFeatures(rawValue: 1 << 9)   // 0x200
    public static let audioRedundant  = AirPlayFeatures(rawValue: 1 << 11)  // 0x800
    public static let fairPlaySecure  = AirPlayFeatures(rawValue: 1 << 12)  // 0x1000
    public static let photoCache      = AirPlayFeatures(rawValue: 1 << 13)  // 0x2000
    public static let authentication  = AirPlayFeatures(rawValue: 1 << 14)  // 0x4000 - Requires pairing
    public static let metadata        = AirPlayFeatures(rawValue: 1 << 15)  // 0x8000
    public static let audioFormats    = AirPlayFeatures(rawValue: 1 << 16)  // 0x10000
    public static let audioControl    = AirPlayFeatures(rawValue: 1 << 17)  // 0x20000

    /// Video playback support (what Beamy needs)
    public var supportsVideo: Bool {
        contains(.video) || contains(.videoHTTPLive) || contains(.videoFairPlay)
    }

    /// Requires PIN pairing before use
    public var requiresPairing: Bool {
        contains(.authentication)
    }
}

public struct AirPlayDevice: Sendable, Hashable, Equatable {
    public let name: String
    public let address: String
    public let port: Int
    public let deviceId: String
    public let model: String?
    public let airplayVersion: String?
    public let features: AirPlayFeatures

    public init(
        name: String,
        address: String,
        port: Int = 7000,
        deviceId: String,
        model: String? = nil,
        airplayVersion: String? = nil,
        features: AirPlayFeatures = []
    ) {
        self.name = name
        self.address = address
        self.port = port
        self.deviceId = deviceId
        self.model = model
        self.airplayVersion = airplayVersion
        self.features = features
    }

    // MARK: - Computed Properties

    /// Returns true if the device supports video playback (what Beamy needs)
    public var isVideoCapable: Bool {
        features.supportsVideo
    }

    /// Returns true if the device requires PIN pairing
    public var requiresPairing: Bool {
        features.requiresPairing
    }

    /// Returns true if the device has a valid (non-empty) IP address
    public var hasValidAddress: Bool {
        !address.isEmpty
    }

    /// Human-readable capability description
    public var capabilityDescription: String {
        var caps: [String] = []
        if features.supportsVideo { caps.append("Video") }
        if features.contains(.audio) { caps.append("Audio") }
        if features.contains(.screen) { caps.append("Mirroring") }
        return caps.isEmpty ? "Unknown" : caps.joined(separator: " + ")
    }

    /// Device type description based on model
    public var deviceType: String {
        guard let model = model?.lowercased() else { return "AirPlay Device" }

        if model.contains("appletv") { return "Apple TV" }
        if model.contains("homepod") { return "HomePod" }
        if model.contains("airportexpress") { return "AirPort Express" }
        if model.contains("samsung") { return "Samsung TV" }
        if model.contains("lg") { return "LG TV" }
        if model.contains("sony") { return "Sony TV" }
        if model.contains("vizio") { return "Vizio TV" }
        if model.contains("roku") { return "Roku" }

        return "AirPlay Device"
    }

    /// Pairing status description
    public var pairingStatus: String {
        requiresPairing ? "Pairing Required" : "Ready"
    }
}
