import Foundation
import TOMLKit

struct Config: Codable {
    var ffmpeg: FFmpegConfig
    var server: ServerConfig
    var chromecast: ChromecastConfig

    struct FFmpegConfig: Codable {
        var ffmpegPath: String
        var ffprobePath: String
        var preset: String
        var crf: Int
        var audioBitrate: String

        static var `default`: FFmpegConfig {
            FFmpegConfig(
                ffmpegPath: findExecutable("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg",
                ffprobePath: findExecutable("ffprobe") ?? "/opt/homebrew/bin/ffprobe",
                preset: "ultrafast",
                crf: 23,
                audioBitrate: "192k"
            )
        }
    }

    struct ServerConfig: Codable {
        var portRangeStart: Int
        var portRangeEnd: Int

        static var `default`: ServerConfig {
            ServerConfig(
                portRangeStart: 8080,
                portRangeEnd: 9000
            )
        }
    }

    struct ChromecastConfig: Codable {
        var discoveryTimeout: Double
        var defaultDevice: String?

        static var `default`: ChromecastConfig {
            ChromecastConfig(
                discoveryTimeout: 5.0,
                defaultDevice: nil
            )
        }
    }

    static var `default`: Config {
        Config(
            ffmpeg: .default,
            server: .default,
            chromecast: .default
        )
    }

    static var configDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var configPath: URL {
        configDirectory.appendingPathComponent("beamster.toml")
    }

    static func load() throws -> Config {
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

    func save() throws {
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

    func toTOMLString() -> String {
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
