import SwiftUI
import BeamyKit
import Combine

// MARK: - Output Type

enum OutputType: String, CaseIterable {
    case mpv = "mpv"
    case chromecast = "chromecast"
}

// MARK: - Player Handle

private struct PlayerHandle {
    let output: OutputType
    let player: Player
    let cleanup: () -> Void
}

// MARK: - CastingViewModel

@MainActor
class CastingViewModel: ObservableObject {
    // MARK: Published State

    @Published var devices: [ChromecastDevice] = []
    @Published var selectedDevice: ChromecastDevice? {
        didSet { saveSelectedDevice() }
    }
    @Published var currentFile: URL?
    @Published var mediaInfo: MediaInfo?
    @Published var duration: TimeInterval = 0
    @Published var isDiscovering = false
    @Published var errorMessage: String?
    @Published var outputType: OutputType = .mpv {
        didSet { saveOutputType() }
    }
    @Published var isSwitchingOutput = false
    @Published var statusMessage: String = "Drop a video file to start"
    @Published var useEmbeddedPlayer: Bool = true  // AVPlayer embedded playback

    // Embedded player state (for AVPlayerView binding)
    @Published var embeddedIsPlaying: Bool = false
    @Published var embeddedCurrentTime: TimeInterval = 0
    @Published var embeddedDuration: TimeInterval = 0

    @Published var transcodeServer: TranscodeServer?

    // MARK: Internal State
    private var playerHandle: PlayerHandle?
    private var positionTimer: Timer?
    private var isLoadingConfig = false

    // Position tracking (like TUI)
    private var lastKnownPosition: TimeInterval = 0
    private var lastKnownPaused: Bool = true
    private var chromecastSeekOffset: TimeInterval = 0
    var embeddedPlayerCoordinator: AVPlayerView.Coordinator?

    // MARK: Computed Properties (query Player, not TranscodeServer)

    var isPlaying: Bool {
        // For embedded AVPlayer, use the binding state
        if useEmbeddedPlayer && outputType == .mpv {
            return embeddedIsPlaying
        }
        guard let player = playerHandle?.player else { return false }
        return !((try? player.isPaused()) ?? true)
    }

    var currentTime: TimeInterval {
        // For embedded AVPlayer, use the binding state
        if useEmbeddedPlayer && outputType == .mpv {
            return embeddedCurrentTime
        }
        guard let player = playerHandle?.player else { return lastKnownPosition }

        // For Chromecast LIVE streams, add seek offset (like TUI)
        if player is ChromecastPlayer, let playerTime = try? player.getPosition() {
            return chromecastSeekOffset + playerTime
        }

        return (try? player.getPosition()) ?? lastKnownPosition
    }

    var effectiveDuration: TimeInterval {
        // For embedded mpv, use the binding state if available
        if useEmbeddedPlayer && outputType == .mpv && embeddedDuration > 0 {
            return embeddedDuration
        }
        return duration
    }

    var progress: Double {
        effectiveDuration > 0 ? currentTime / effectiveDuration : 0
    }

    var timeRemaining: TimeInterval {
        max(0, effectiveDuration - currentTime)
    }

    var hasPlayer: Bool {
        if useEmbeddedPlayer && outputType == .mpv {
            return currentFile != nil
        }
        return playerHandle != nil
    }


    // MARK: Initialization

    init() {
        isLoadingConfig = true
        loadConfig()
        discoverDevices()
        isLoadingConfig = false
    }

    private func loadConfig() {
        guard let config = try? Config.load() else { return }

        // Restore output type
        if let savedOutput = config.ui.defaultOutput?.lowercased() {
            switch savedOutput {
            case "mpv": outputType = .mpv
            case "chromecast": outputType = .chromecast
            default: break
            }
        }
    }

    // MARK: Config Persistence

    private func saveSelectedDevice() {
        guard !isLoadingConfig else { return }
        guard var config = try? Config.load() else { return }
        config.chromecast.defaultDevice = selectedDevice?.name
        try? config.save()
    }

    private func saveOutputType() {
        guard !isLoadingConfig else { return }
        guard var config = try? Config.load() else { return }
        config.ui.defaultOutput = outputType.rawValue
        try? config.save()
    }

    // MARK: Device Discovery

    func discoverDevices() {
        guard !isDiscovering else { return }
        isDiscovering = true
        errorMessage = nil

        Task {
            do {
                let timeout = (try? Config.load().chromecast.discoveryTimeout) ?? 5.0
                let allDevices = try ChromecastDiscovery.discover(timeout: timeout)
                let videoDevices = allDevices.filter { $0.isVideoCapable }

                await MainActor.run {
                    self.devices = videoDevices
                    self.isDiscovering = false

                    // Restore saved device
                    if let defaultName = try? Config.load().chromecast.defaultDevice {
                        self.isLoadingConfig = true
                        self.selectedDevice = videoDevices.first { $0.name == defaultName }
                        self.isLoadingConfig = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Discovery failed: \(error.localizedDescription)"
                    self.isDiscovering = false
                }
            }
        }
    }

    // MARK: File Handling (drag-and-drop)

    func handleFileDrop(url: URL) {
        let videoExtensions = ["mp4", "mkv", "webm", "mov", "avi", "m4v"]
        guard videoExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "Unsupported file type. Please drop a video file."
            return
        }

        stopPlayback()
        errorMessage = nil

        // For embedded AVPlayer playback
        if useEmbeddedPlayer && outputType == .mpv {
            let canPlay = AVPlayerView.canPlay(url: url)

            if canPlay {
                // AVPlayer can play this - load directly (no transcoding)
                currentFile = url
                statusMessage = "Playing embedded"
                embeddedIsPlaying = true
            } else {
                // Format not supported by AVPlayer
                errorMessage = "Format not supported. Please use MP4 or MOV files."
                statusMessage = "Drop a video file to start"
            }
            return
        }

        // For non-embedded playback (Chromecast), we need transcoder
        currentFile = url
        statusMessage = "Loading..."

        // Run ffprobe off the main actor to avoid UI hangs
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let info = try FFmpeg.getMediaInfo(file: url)
                await MainActor.run {
                    self.mediaInfo = info
                    self.duration = info.duration
                    self.startTranscoder()
                    self.statusMessage = "Ready to cast"
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to read media info: \(error.localizedDescription)"
                    self.statusMessage = "Drop a video file to start"
                }
            }
        }
    }

    private func startTranscoder() {
        guard let url = currentFile, let info = mediaInfo else { return }

        let port = findAvailablePort()

        do {
            let server = try TranscodeServer(input: url, port: port, mediaInfo: info)
            self.transcodeServer = server
            statusMessage = "Transcoder running"

            // Position timer only needed for external players (Chromecast)
            if outputType == .chromecast {
                startPositionTimer()
            }
        } catch {
            errorMessage = "Failed to start transcoder: \(error.localizedDescription)"
        }
    }

    private func findAvailablePort() -> Int {
        for port in 8080..<9000 {
            if isPortAvailable(port) {
                return port
            }
        }
        return 8080
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result >= 0
    }

    // MARK: Position Timer (250ms polling like TUI)

    private func startPositionTimer() {
        if useEmbeddedPlayer && outputType == .mpv {
            return
        }
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPosition()
            }
        }
    }

    private func pollPosition() {
        guard let player = playerHandle?.player else {
            statusMessage = transcodeServer != nil ? "Ready - press Play" : "Drop a video file to start"
            return
        }

        // Update position from player
        if let position = try? player.getPosition() {
            if player is ChromecastPlayer {
                lastKnownPosition = chromecastSeekOffset + position
            } else {
                lastKnownPosition = position
            }
        }

        // Update pause state
        if let paused = try? player.isPaused() {
            lastKnownPaused = paused
        }

        // Update status
        let outputName = outputType == .mpv ? "mpv" : "Chromecast"
        statusMessage = lastKnownPaused ? "Paused via \(outputName)" : "Playing via \(outputName)"

        // Trigger UI refresh
        objectWillChange.send()
    }

    // MARK: Output Switching

    func switchOutput(to newOutput: OutputType) {
        guard !isSwitchingOutput else {
            statusMessage = "Output switch in progress..."
            return
        }

        // Embedded path (local AVPlayer)
        if useEmbeddedPlayer && newOutput == .mpv {
            outputType = newOutput
            statusMessage = "Playing embedded"
            return
        }

        // Switching to Chromecast from embedded playback
        if useEmbeddedPlayer && outputType == .mpv && newOutput == .chromecast {
            let position = embeddedCurrentTime
            if transcodeServer == nil {
                startTranscoder()
            }
            if let server = transcodeServer {
                server.seek(to: position)
            }
            outputType = newOutput

            guard selectedDevice != nil else {
                statusMessage = "Select a Chromecast device"
                return
            }

            isSwitchingOutput = true
            statusMessage = "Switching to Chromecast..."

            Task {
                do {
                    try await launchPlayer(output: newOutput, seekTo: position, paused: false)
                    statusMessage = "Playing via Chromecast"
                } catch {
                    errorMessage = "Failed to switch output: \(error.localizedDescription)"
                    statusMessage = "Output switch failed"
                }
                isSwitchingOutput = false
            }
            return
        }

        guard transcodeServer != nil else {
            outputType = newOutput
            return
        }

        // If switching to Chromecast but no device selected, don't switch yet
        if newOutput == .chromecast && selectedDevice == nil {
            outputType = newOutput
            statusMessage = "Select a Chromecast device"
            return
        }

        isSwitchingOutput = true
        statusMessage = "Switching output..."

        // Capture current state
        let position = currentTime
        let wasPaused = lastKnownPaused

        // Cleanup old player
        cleanupPlayer()

        // Update output type
        outputType = newOutput

        // Launch new player
        Task {
            do {
                try await launchPlayer(output: newOutput, seekTo: position, paused: wasPaused)
                statusMessage = newOutput == .mpv ? "Playing embedded" : "Playing via Chromecast"
            } catch {
                errorMessage = "Failed to switch output: \(error.localizedDescription)"
                statusMessage = "Output switch failed"
            }
            isSwitchingOutput = false
        }
    }

    private func launchPlayer(output: OutputType, seekTo position: TimeInterval, paused: Bool) async throws {
        guard let server = transcodeServer else { return }

        switch output {
        case .mpv:
            // Embedded playback handles mpv output type when enabled
            if useEmbeddedPlayer {
                return
            }
            let handle = try launchMpv(server: server, seekTo: position, paused: paused)
            playerHandle = handle

        case .chromecast:
            guard let device = selectedDevice else {
                throw PlayerError.disconnected
            }
            let handle = try await launchChromecast(device: device, server: server, seekTo: position, paused: paused)
            playerHandle = handle
        }

        lastKnownPosition = position
        lastKnownPaused = paused
    }

    private func launchMpv(server: TranscodeServer, seekTo position: TimeInterval, paused: Bool) throws -> PlayerHandle {
        let controller = MpvController()
        _ = try controller.launch(url: server.url, windowTitle: "Beamy Player")

        let player = MpvPlayer(controller: controller, server: server, streamURL: server.url)

        if position > 0 {
            try? player.seek(to: position)
        }
        if paused {
            try? player.pause()
        }

        return PlayerHandle(output: .mpv, player: player, cleanup: {
            controller.quit()
        })
    }

    private func launchChromecast(device: ChromecastDevice, server: TranscodeServer, seekTo position: TimeInterval, paused: Bool) async throws -> PlayerHandle {
        let client = CastV2Client(device: device, verbose: false)
        try client.connect()
        try client.launchDefaultMediaReceiver()

        // For LIVE streams, seek server BEFORE loading
        if position > 0 {
            server.seek(to: position, awaitClientReconnect: false)
            chromecastSeekOffset = position
        } else {
            chromecastSeekOffset = 0
        }

        let title = currentFile?.lastPathComponent ?? "Beamy Stream"
        try client.loadMedia(url: server.url, contentType: "application/vnd.apple.mpegurl", title: title, isLive: true)

        let player = ChromecastPlayer(client: client)

        if paused {
            try? player.pause()
        }

        // Ensure position polling is active for Chromecast
        if positionTimer == nil {
            startPositionTimer()
        }

        return PlayerHandle(output: .chromecast, player: player, cleanup: {
            client.disconnect()
        })
    }

    // MARK: Playback Controls

    func togglePlayPause() {
        // Embedded AVPlayer path
        if useEmbeddedPlayer && outputType == .mpv {
            embeddedPlayerCoordinator?.togglePause()
            return
        }

        // If no player, launch one first
        if playerHandle == nil {
            guard transcodeServer != nil else { return }

            // For Chromecast, need device selected
            if outputType == .chromecast && selectedDevice == nil {
                statusMessage = "Select a Chromecast device first"
                return
            }

            Task {
                do {
                    try await launchPlayer(output: outputType, seekTo: 0, paused: false)
                } catch {
                    errorMessage = "Failed to start playback: \(error.localizedDescription)"
                }
            }
            return
        }

        guard let player = playerHandle?.player else { return }

        do {
            if lastKnownPaused {
                try player.resume()
                lastKnownPaused = false
            } else {
                try player.pause()
                lastKnownPaused = true
            }
        } catch {
            errorMessage = "Playback control error: \(error.localizedDescription)"
        }
    }

    func skipForward() {
        let target = currentTime + 10
        if useEmbeddedPlayer && outputType == .mpv {
            let clamped = min(target, effectiveDuration)
            embeddedPlayerCoordinator?.seek(to: clamped)
            embeddedCurrentTime = clamped
        } else {
            seek(to: target)
        }
    }

    func skipBackward() {
        let target = max(0, currentTime - 10)
        if useEmbeddedPlayer && outputType == .mpv {
            embeddedPlayerCoordinator?.seek(to: target)
            embeddedCurrentTime = target
        } else {
            seek(to: target)
        }
    }

    func seek(to time: TimeInterval) {
        let dur = useEmbeddedPlayer && outputType == .mpv ? effectiveDuration : duration
        let clamped = min(max(0, time), dur)

        // For embedded AVPlayer, control via coordinator
        if useEmbeddedPlayer && outputType == .mpv {
            embeddedPlayerCoordinator?.seek(to: clamped)
            embeddedCurrentTime = clamped
            return
        }

        guard let player = playerHandle?.player else {
            lastKnownPosition = clamped
            return
        }

        do {
            // For Chromecast, reload stream at new position (LIVE streams don't support SEEK)
            if let chromecastPlayer = player as? ChromecastPlayer, let server = transcodeServer {
                chromecastSeekOffset = clamped
                server.seek(to: clamped, awaitClientReconnect: true)
                try chromecastPlayer.reload(url: server.url)
            } else {
                try player.seek(to: clamped)
            }
            lastKnownPosition = clamped
        } catch {
            errorMessage = "Seek error: \(error.localizedDescription)"
        }
    }

    func seekToProgress(_ progress: Double) {
        let dur = useEmbeddedPlayer && outputType == .mpv ? effectiveDuration : duration
        seek(to: progress * dur)
    }

    // MARK: Cleanup

    private func cleanupPlayer() {
        playerHandle?.cleanup()
        playerHandle = nil
    }

    func stopPlayback() {
        cleanupPlayer()
        positionTimer?.invalidate()
        positionTimer = nil
        transcodeServer?.stop()
        transcodeServer = nil
        lastKnownPosition = 0
        lastKnownPaused = true
        chromecastSeekOffset = 0
        embeddedIsPlaying = false
        embeddedCurrentTime = 0
        embeddedDuration = 0
        currentFile = nil
        mediaInfo = nil
        duration = 0
        statusMessage = "Drop a video file to start"
    }

    // MARK: Helpers

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00:00" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
