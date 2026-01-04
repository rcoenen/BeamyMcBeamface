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

    @Flag(help: "Use mpv with IPC for playback")
    var mpv: Bool = false

    @Option(name: .long, help: "Chromecast device name or IP for playback")
    var chromecast: String?

    func run() throws {
        // Clear old logs
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-tui.log")
        try? FileManager.default.removeItem(atPath: "/tmp/beamy-transcoder-debug.log")

        let inputURL = URL(fileURLWithPath: inputFile)

        guard FileManager.default.fileExists(atPath: inputFile) else {
            throw ValidationError("File not found: \(inputFile)")
        }

        print("=== TRANSCODE TEST ===")
        print("Input: \(inputURL.lastPathComponent)")
        print("Port: \(port)")
        print("")

        print("Getting media info...")
        let mediaInfo = try FFmpeg.getMediaInfo(file: inputURL)
        print("Duration: \(formatTime(mediaInfo.duration))")
        print("")

        print("Starting transcoder server...")
        let server = try TranscodeServer(input: inputURL, port: port, mediaInfo: mediaInfo)

        print("")
        print("========================================")
        print("Stream ready at: \(server.url)")
        print("========================================")
        print("")

        if let chromecast = chromecast {
            try runChromecastMode(
                server: server,
                duration: mediaInfo.duration,
                deviceNameOrIP: chromecast,
                title: inputURL.deletingPathExtension().lastPathComponent
            )
        } else if mpv {
            try runMpvMode(server: server, duration: mediaInfo.duration)
        } else {
            throw ValidationError("Select a player: --mpv or --chromecast <device>")
        }
    }

    private func runMpvMode(server: TranscodeServer, duration: TimeInterval) throws {
        let controller = MpvController()
        _ = try controller.launch(url: server.url, windowTitle: "Beamy Player (mpv)")
        let player = MpvPlayer(controller: controller, server: server, streamURL: server.url)
        let ui = TermKitTranscoderUI(player: player, duration: duration)
        try ui.run()
    }

    private func runChromecastMode(
        server: TranscodeServer,
        duration: TimeInterval,
        deviceNameOrIP: String,
        title: String
    ) throws {
        let device = try resolveDevice(nameOrIP: deviceNameOrIP)
        print("Connecting to Chromecast: \(device.name)...")
        let client = CastV2Client(device: device, verbose: true)
        try client.connect()
        try client.launchDefaultMediaReceiver()
        try client.loadMedia(url: server.url, contentType: "video/mp2t", title: title, isLive: true)
        let player = ChromecastPlayer(client: client)
        let ui = TermKitTranscoderUI(player: player, duration: duration)
        try ui.run()
    }

    private func resolveDevice(nameOrIP: String) throws -> ChromecastDevice {
        if let device = try ChromecastDiscovery.findDevice(named: nameOrIP, timeout: 5.0) {
            return device
        }
        throw ValidationError("Chromecast device not found: \(nameOrIP)")
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "NaN" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
