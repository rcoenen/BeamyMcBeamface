import Foundation
import TOMLKit

public struct Config: Codable {
    public var ffmpeg: FFmpegConfig
    public var server: ServerConfig
    public var chromecast: ChromecastConfig
    public var airplay: AirPlayConfig
    public var ui: UIConfig

    enum CodingKeys: String, CodingKey {
        case ffmpeg
        case server
        case chromecast
        case airplay
        case ui
    }

    public init(ffmpeg: FFmpegConfig, server: ServerConfig, chromecast: ChromecastConfig, airplay: AirPlayConfig, ui: UIConfig) {
        self.ffmpeg = ffmpeg
        self.server = server
        self.chromecast = chromecast
        self.airplay = airplay
        self.ui = ui
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ffmpeg = try container.decodeIfPresent(FFmpegConfig.self, forKey: .ffmpeg) ?? .default
        server = try container.decodeIfPresent(ServerConfig.self, forKey: .server) ?? .default
        chromecast = try container.decodeIfPresent(ChromecastConfig.self, forKey: .chromecast) ?? .default
        airplay = try container.decodeIfPresent(AirPlayConfig.self, forKey: .airplay) ?? .default
        ui = try container.decodeIfPresent(UIConfig.self, forKey: .ui) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ffmpeg, forKey: .ffmpeg)
        try container.encode(server, forKey: .server)
        try container.encode(chromecast, forKey: .chromecast)
        try container.encode(airplay, forKey: .airplay)
        try container.encode(ui, forKey: .ui)
    }

    public struct FFmpegConfig: Codable {
        public var ffmpegPath: String
        public var ffprobePath: String
        public var preset: String
        public var crf: Int
        public var audioBitrate: String

        public static var `default`: FFmpegConfig {
            FFmpegConfig(
                ffmpegPath: findExecutable("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg",
                ffprobePath: findExecutable("ffprobe") ?? "/opt/homebrew/bin/ffprobe",
                preset: "ultrafast",
                crf: 23,
                audioBitrate: "192k"
            )
        }
    }

    public struct ServerConfig: Codable {
        public var portRangeStart: Int
        public var portRangeEnd: Int

        public static var `default`: ServerConfig {
            ServerConfig(
                portRangeStart: 8080,
                portRangeEnd: 9000
            )
        }
    }

    public struct ChromecastConfig: Codable {
        public var discoveryTimeout: Double
        public var defaultDevice: String?

        public static var `default`: ChromecastConfig {
            ChromecastConfig(
                discoveryTimeout: 5.0,
                defaultDevice: nil
            )
        }
    }

    public struct AirPlayConfig: Codable {
        public var discoveryTimeout: Double
        public var defaultDevice: String?

        public static var `default`: AirPlayConfig {
            AirPlayConfig(
                discoveryTimeout: 5.0,
                defaultDevice: nil
            )
        }
    }

    public struct UIConfig: Codable {
        /// "mpv", "chromecast", or "airplay"
        public var defaultOutput: String?

        public static var `default`: UIConfig {
            UIConfig(defaultOutput: nil)
        }
    }

    public static var `default`: Config {
        Config(
            ffmpeg: .default,
            server: .default,
            chromecast: .default,
            airplay: .default,
            ui: .default
        )
    }

    public static var configDirectory: URL {
        // For GUI apps, use Application Support; for CLI, use current directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("Beamy")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    public static var configPath: URL {
        configDirectory.appendingPathComponent("beamy.toml")
    }

    public static func load() throws -> Config {
        let path = configPath

        // If config doesn't exist, create it with defaults
        if !FileManager.default.fileExists(atPath: path.path) {
            let config = Config.default
            try config.save()
            return config
        }

        let data = try Data(contentsOf: path)
        let tomlString = String(data: data, encoding: .utf8) ?? ""
        let table = try TOMLTable(string: tomlString)

        return try TOMLDecoder().decode(Config.self, from: table)
    }

    public func save() throws {
        let directory = Self.configDirectory

        // Create config directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let table = try TOMLEncoder().encode(self)
        let tomlString = table.description

        try tomlString.write(to: Self.configPath, atomically: true, encoding: .utf8)
    }

    public func toTOMLString() -> String {
        do {
            let table = try TOMLEncoder().encode(self)
            return table.description
        } catch {
            return "Error encoding config: \(error)"
        }
    }
}

private func findExecutable(_ name: String) -> String? {
    let paths = [
        "/opt/homebrew/bin/\(name)",  // ARM Mac
        "/usr/local/bin/\(name)",      // Intel Mac
    ]

    for path in paths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }

    // Try using `which`
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    } catch {
        return nil
    }

    return nil
}
