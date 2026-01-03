import ArgumentParser
import Foundation

struct FFmpegDiscover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ffmpeg-discover",
        abstract: "Discover FFmpeg binaries and update configuration"
    )

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() throws {
        print("Searching for FFmpeg binaries...")

        // Find all FFmpeg installations
        let ffmpegPaths = findAllExecutables("ffmpeg")
        let ffprobePaths = findAllExecutables("ffprobe")

        if ffmpegPaths.isEmpty && ffprobePaths.isEmpty {
            print("\nNo FFmpeg binaries found.")
            print("\nPlease install FFmpeg:")
            print("  brew install ffmpeg")
            throw ExitCode.failure
        }

        // Select ffmpeg
        print("\nFound ffmpeg binaries:\n")
        let ffmpegPath = try selectExecutable(paths: ffmpegPaths, name: "ffmpeg")

        // Select ffprobe
        print("\nFound ffprobe binaries:\n")
        let ffprobePath = try selectExecutable(paths: ffprobePaths, name: "ffprobe")

        // Get version info
        if verbose {
            print("\nVersion information:")
            if let ffmpegVersion = getVersion(ffmpegPath) {
                print("  ffmpeg:  \(ffmpegVersion)")
            }
            if let ffprobeVersion = getVersion(ffprobePath) {
                print("  ffprobe: \(ffprobeVersion)")
            }
        }

        // Test ffprobe works
        print("\nTesting ffprobe...")
        if !testFFprobe(ffprobePath) {
            throw ValidationError("ffprobe test failed - binary may be corrupted")
        }
        print("  ✓ ffprobe working")

        // Update config
        var config = (try? Config.load()) ?? .default
        config.ffmpeg.ffmpegPath = ffmpegPath
        config.ffmpeg.ffprobePath = ffprobePath

        try config.save()

        print("\n✓ Configuration updated: beamster.toml")
        print("\nFFmpeg settings:")
        print("  ffmpeg:        \(ffmpegPath)")
        print("  ffprobe:       \(ffprobePath)")
        print("  Preset:        \(config.ffmpeg.preset)")
        print("  CRF:           \(config.ffmpeg.crf)")
        print("  Audio bitrate: \(config.ffmpeg.audioBitrate)")
    }

    private func selectExecutable(paths: [String], name: String) throws -> String {
        if paths.isEmpty {
            print("No \(name) binaries found.")
            return try manualEntry(name: name)
        }

        // Display found binaries
        for (index, path) in paths.enumerated() {
            print("  \(index + 1). \(path)")
            if verbose, let version = getVersion(path) {
                print("     \(version)")
            }
            print()
        }

        // Selection loop
        while true {
            print("Select \(name) (1-\(paths.count)), enter custom path, or press Enter to cancel: ", terminator: "")
            fflush(stdout)

            guard let input = readLine() else {
                print("\nCancelled. Configuration not modified.")
                throw ExitCode.failure
            }

            let trimmedInput = input.trimmingCharacters(in: .whitespaces)
            if trimmedInput.isEmpty {
                print("Cancelled. Configuration not modified.")
                throw ExitCode.failure
            }

            // Try to parse as number (selection from list)
            if let selection = Int(trimmedInput),
               selection >= 1 && selection <= paths.count {
                return paths[selection - 1]
            }

            // Otherwise treat as custom path
            let customPath = trimmedInput
            if FileManager.default.fileExists(atPath: customPath) {
                if verbose {
                    print("Using custom path: \(customPath)")
                }
                return customPath
            } else {
                print("Error: File not found at '\(customPath)'")
                print("Please enter a valid path or select from the list.")
                continue
            }
        }
    }

    private func manualEntry(name: String) throws -> String {
        while true {
            print("Enter path to \(name) binary or press Enter to cancel: ", terminator: "")
            fflush(stdout)

            guard let input = readLine() else {
                print("\nCancelled. Configuration not modified.")
                throw ExitCode.failure
            }

            let trimmedInput = input.trimmingCharacters(in: .whitespaces)
            if trimmedInput.isEmpty {
                print("Cancelled. Configuration not modified.")
                throw ExitCode.failure
            }

            if FileManager.default.fileExists(atPath: trimmedInput) {
                return trimmedInput
            } else {
                print("Error: File not found at '\(trimmedInput)'")
                continue
            }
        }
    }

    private func findAllExecutables(_ name: String) -> [String] {
        var found: [String] = []

        let searchPaths = [
            "/opt/homebrew/bin/\(name)",  // ARM Mac (Homebrew)
            "/usr/local/bin/\(name)",      // Intel Mac (Homebrew)
            "/usr/bin/\(name)",            // System
            "/bin/\(name)",                // System
        ]

        // Check common paths
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) && !found.contains(path) {
                found.append(path)
            }
        }

        // Also try `which` to find in PATH
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
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !found.contains(path) {
                    found.append(path)
                }
            }
        } catch {
            // Ignore errors
        }

        return found
    }

    private func getVersion(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Extract first line (version info)
                return output.components(separatedBy: .newlines).first
            }
        } catch {
            return nil
        }

        return nil
    }

    private func testFFprobe(_ path: String) -> Bool {
        // Test ffprobe by asking for version in JSON format
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-version",
            "-of", "json"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
