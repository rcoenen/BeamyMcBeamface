import ArgumentParser
import BeamyKit
import Foundation

struct TranscodeTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcode-test",
        abstract: "Test transcoder with seek/pause/resume - device-authoritative playback"
    )

    @Argument(help: "Input video file path")
    var inputFile: String

    @Option(name: .shortAndLong, help: "Port for HTTP server")
    var port: Int = 8080

    func run() throws {
        // Clear old logs
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-tui.log")
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-cast.log")
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-transcoder-debug.log")

        let inputURL = URL(fileURLWithPath: inputFile)

        guard FileManager.default.fileExists(atPath: inputFile) else {
            throw ValidationError("File not found: \(inputFile)")
        }

        // Log to file instead of stdout (terminal is the UI)
        let logURL = URL(fileURLWithPath: "/tmp/beamy-tui.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        func log(_ message: String) {
            let line = "[INIT] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }

        log("=== TRANSCODE TEST ===")
        log("Input: \(inputURL.lastPathComponent)")
        log("Port: \(port)")

        log("Getting media info...")
        let mediaInfo = try FFmpeg.getMediaInfo(file: inputURL)
        log("Duration: \(formatTime(mediaInfo.duration))")

        log("Starting transcoder server...")
        let server = try TranscodeServer(input: inputURL, port: port, mediaInfo: mediaInfo)

        log("Stream ready at: \(server.url)")

        let config = try Config.load()

        let ui = TermKitTranscoderUI(
            server: server,
            duration: mediaInfo.duration,
            title: inputURL.deletingPathExtension().lastPathComponent,
            config: config,
            initialOutput: nil,
            onCleanup: nil
        )
        try ui.run()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "NaN" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
