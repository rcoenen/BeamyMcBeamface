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
        didSet {
            saveSelectedDevice()
            // Show promo on Chromecast when device selected but no video loaded
            if selectedDevice != nil && outputType == .chromecast && currentFile == nil {
                showPromoOnChromecast()
            }
        }
    }
    @Published var currentFile: URL?
    @Published var mediaInfo: MediaInfo?
    @Published var duration: TimeInterval = 0
    @Published var isDiscovering = false
    @Published var errorMessage: String?
    @Published var outputType: OutputType = .mpv {
        didSet {
            saveOutputType()

            // Show promo when switching TO Chromecast (if device selected but no video)
            if outputType == .chromecast && selectedDevice != nil && currentFile == nil {
                showPromoOnChromecast()
            }

            // Disconnect from Chromecast when switching TO Beamy
            if outputType == .mpv {
                try? promoCastClient?.stopMedia()
                promoCastClient?.disconnect()
                promoCastClient = nil
                print("[OUTPUT] Disconnected from Chromecast (switched to Beamy)")
            }
        }
    }
    @Published var isSwitchingOutput = false
    @Published var statusMessage: String = "Drop a video file to start"
    @Published var useEmbeddedPlayer: Bool = true  // AVPlayer embedded playback

    // Embedded player state (for AVPlayerView binding)
    @Published var embeddedIsPlaying: Bool = false {
        didSet {
            // Update status message when playback state changes
            if useEmbeddedPlayer && outputType == .mpv && currentFile != nil {
                statusMessage = embeddedIsPlaying ? "Playing" : "Paused"
            }
        }
    }
    @Published var embeddedCurrentTime: TimeInterval = 0
    @Published var embeddedDuration: TimeInterval = 0

    @Published var transcodeServer: TranscodeServer?
    @Published var isStreamReady: Bool = false  // True when HLS stream is actually available
    @Published private(set) var isArbitrarySeeking: Bool = false

    // MARK: Internal State
    private var playerHandle: PlayerHandle?
    private var positionTimer: Timer?
    private var isLoadingConfig = false
    private var promoImageServer: PromoImageServer?
    private var promoCastClient: CastV2Client?  // Keep promo client alive

    // Position tracking (like TUI)
    private var lastKnownPosition: TimeInterval = 0
    private var lastKnownPaused: Bool = true
    private var chromecastSeekOffset: TimeInterval = 0
    private var embeddedSeekOffset: TimeInterval = 0
    var embeddedPlayerCoordinator: AVPlayerView.Coordinator?
    var mpvPlayerCoordinator: MpvPlayerView.Coordinator?
    var hlsWebPlayerCoordinator: HLSWebPlayerView.Coordinator?

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
            return embeddedSeekOffset + embeddedCurrentTime
        }
        guard let player = playerHandle?.player else { return lastKnownPosition }

        // For Chromecast LIVE streams, add seek offset (like TUI)
        if player is ChromecastPlayer, let playerTime = try? player.getPosition() {
            return chromecastSeekOffset + playerTime
        }

        return (try? player.getPosition()) ?? lastKnownPosition
    }

    var effectiveDuration: TimeInterval {
        // For embedded mode, use mediaInfo duration (not HLS stream duration which resets on seeks)
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

        print("DEBUG: handleFileDrop called with \(url.lastPathComponent)")
        print("DEBUG: outputType=\(outputType), selectedDevice=\(selectedDevice?.name ?? "nil")")
        print("DEBUG: promoCastClient exists: \(promoCastClient != nil)")

        // Preserve Chromecast session when dropping new file - we'll reuse it
        let preservedClient = (outputType == .chromecast) ? promoCastClient : nil
        stopPlayback()
        promoCastClient = preservedClient
        print("DEBUG: after stopPlayback, promoCastClient exists: \(promoCastClient != nil)")
        errorMessage = nil
        currentFile = url
        statusMessage = "Loading..."
        embeddedSeekOffset = 0

        // Get media info first
        Task.detached { [weak self] in
            guard let self else { return }
            print("DEBUG: Starting ffprobe...")
            do {
                let info = try FFmpeg.getMediaInfo(file: url)
                print("DEBUG: ffprobe done, duration: \(info.duration)")
                await MainActor.run {
                    self.mediaInfo = info
                    self.duration = info.duration
                    self.embeddedDuration = info.duration
                    self.embeddedIsPlaying = true

                    // For embedded playback, set isStreamReady immediately
                    // The WebView will trigger transcoder start when it's ready
                    if self.useEmbeddedPlayer && self.outputType == .mpv {
                        self.statusMessage = "Ready"
                        self.isStreamReady = true  // Show WebView, it will call startTranscoderForEmbedded
                    } else {
                        // External player path - start transcoder now
                        self.startTranscoder()
                        self.statusMessage = "Transcoding..."
                    }
                }
            } catch {
                print("DEBUG: ffprobe error: \(error)")
                await MainActor.run {
                    self.errorMessage = "Failed to read media info: \(error.localizedDescription)"
                    self.statusMessage = "Drop a video file to start"
                    self.currentFile = nil
                }
            }
        }
    }

    /// Called by WebView when it's ready to receive the stream
    func startTranscoderForEmbedded() {
        guard useEmbeddedPlayer && outputType == .mpv else { return }
        guard transcodeServer == nil else { return }  // Already running
        guard let url = currentFile, let info = mediaInfo else { return }

        print("DEBUG: Starting transcoder for embedded playback (embeddedMode=true)")
        let port = findAvailablePort()

        do {
            // Use embeddedMode for proper seeking from start
            let server = try TranscodeServer(input: url, port: port, mediaInfo: info, embeddedMode: true)
            self.transcodeServer = server
            statusMessage = "Buffering..."
            embeddedSeekOffset = 0
        } catch {
            errorMessage = "Failed to start transcoder: \(error.localizedDescription)"
        }
    }

    private func startTranscoder() {
        guard let url = currentFile, let info = mediaInfo else {
            print("DEBUG: startTranscoder - no currentFile or mediaInfo")
            return
        }

        let port = findAvailablePort()
        isStreamReady = false

        print("DEBUG: startTranscoder - port=\(port), outputType=\(outputType)")

        do {
            let server = try TranscodeServer(input: url, port: port, mediaInfo: info)
            self.transcodeServer = server
            print("DEBUG: startTranscoder - server created, url=\(server.url)")
            statusMessage = "Starting transcoder..."

            // Poll until HLS stream is ready
            pollForStreamReady(url: server.url)

            // Position timer only needed for external players (Chromecast)
            if outputType == .chromecast {
                startPositionTimer()
            }
        } catch {
            print("DEBUG: startTranscoder - error: \(error)")
            errorMessage = "Failed to start transcoder: \(error.localizedDescription)"
        }
    }

    private func pollForStreamReady(url: URL) {
        // Only used for external players (Chromecast)
        print("DEBUG: pollForStreamReady starting, url=\(url)")
        Task {
            var attempts = 0
            let maxAttempts = 60

            while attempts < maxAttempts {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 2
                    let (_, response) = try await URLSession.shared.data(for: request)

                    if let httpResponse = response as? HTTPURLResponse {
                        print("DEBUG: pollForStreamReady attempt \(attempts) - status \(httpResponse.statusCode)")
                        if httpResponse.statusCode == 200 {
                            await MainActor.run {
                                print("DEBUG: Stream ready! outputType=\(self.outputType), selectedDevice=\(self.selectedDevice?.name ?? "nil"), playerHandle=\(self.playerHandle != nil)")
                                self.isStreamReady = true
                                self.statusMessage = "Ready"

                                // Auto-start Chromecast playback when stream is ready
                                if self.outputType == .chromecast && self.selectedDevice != nil && self.playerHandle == nil {
                                    print("DEBUG: Auto-starting Chromecast playback!")
                                    Task {
                                        do {
                                            try await self.launchPlayer(output: .chromecast, seekTo: 0, paused: false)
                                            self.statusMessage = "Playing via Chromecast"
                                            print("DEBUG: Chromecast playback started successfully")
                                        } catch {
                                            print("DEBUG: Chromecast playback failed: \(error)")
                                            self.errorMessage = "Failed to start Chromecast: \(error.localizedDescription)"
                                        }
                                    }
                                } else {
                                    print("DEBUG: NOT auto-starting - conditions not met")
                                }
                            }
                            return
                        }
                    }
                } catch {
                    if attempts % 10 == 0 {
                        print("DEBUG: pollForStreamReady attempt \(attempts) - error: \(error.localizedDescription)")
                    }
                }

                attempts += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            print("DEBUG: pollForStreamReady TIMEOUT after \(maxAttempts) attempts")
            await MainActor.run {
                self.errorMessage = "Timeout waiting for stream"
            }
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

    private var pollFailCount = 0

    private func pollPosition() {
        guard let player = playerHandle?.player else {
            statusMessage = transcodeServer != nil ? "Ready - press Play" : "Drop a video file to start"
            // Kill zombie timer if no player
            positionTimer?.invalidate()
            positionTimer = nil
            return
        }

        // Update position from player
        if let position = try? player.getPosition() {
            pollFailCount = 0
            if player is ChromecastPlayer {
                lastKnownPosition = chromecastSeekOffset + position
            } else {
                lastKnownPosition = position
            }
        } else {
            // Track failures and kill zombie after too many
            pollFailCount += 1
            if pollFailCount > 10 {
                print("DEBUG: Killing zombie player after \(pollFailCount) poll failures")
                cleanupPlayer()
                positionTimer?.invalidate()
                positionTimer = nil
                pollFailCount = 0
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

        // Switching to embedded from Chromecast
        if useEmbeddedPlayer && newOutput == .mpv && outputType == .chromecast {
            print("DEBUG: Switching from Chromecast to embedded")
            // Capture position before cleanup
            let position = currentTime
            print("DEBUG: Captured position: \(position)")

            // Stop Chromecast player
            print("DEBUG: Calling cleanupPlayer()")
            cleanupPlayer()
            print("DEBUG: cleanupPlayer() done")

            // Restart transcoder at captured position (FFmpeg has transcoded ahead)
            if let server = transcodeServer {
                print("DEBUG: Restarting transcoder at position \(position)")
                server.seek(to: position, awaitClientReconnect: false)
                embeddedSeekOffset = position
            }

            // Switch to embedded
            outputType = newOutput

            statusMessage = "Playing embedded"
            print("DEBUG: Switch complete")
            return
        }

        // Already on embedded, no change needed
        if useEmbeddedPlayer && newOutput == .mpv {
            return
        }

        // Switching to Chromecast from embedded playback
        if useEmbeddedPlayer && outputType == .mpv && newOutput == .chromecast {
            let position = currentTime  // Use full time (embeddedSeekOffset + embeddedCurrentTime)
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
        print("DEBUG: launchChromecast - device=\(device.name), streamURL=\(server.url)")

        // Reuse existing promo client if available, otherwise create new one
        let client: CastV2Client
        if let existingClient = promoCastClient {
            print("DEBUG: launchChromecast - reusing existing promo client")
            client = existingClient
            promoCastClient = nil  // Transfer ownership
        } else {
            print("DEBUG: launchChromecast - creating new client")
            client = CastV2Client(device: device, verbose: true)
            try client.connect()
            try client.launchDefaultMediaReceiver()
        }
        print("DEBUG: launchChromecast - client ready")

        // For LIVE streams, seek server BEFORE loading
        if position > 0 {
            server.seek(to: position, awaitClientReconnect: false)
            chromecastSeekOffset = position
        } else {
            chromecastSeekOffset = 0
        }

        let title = currentFile?.lastPathComponent ?? "Beamy Stream"
        print("DEBUG: launchChromecast - loading media: \(server.url)")
        try client.loadMedia(url: server.url, contentType: "application/vnd.apple.mpegurl", title: title, isLive: true)
        print("DEBUG: launchChromecast - media loaded!")

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
        // Embedded HLS WebView path
        if useEmbeddedPlayer && outputType == .mpv {
            hlsWebPlayerCoordinator?.togglePause()
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
        seek(to: target)
    }

    func skipBackward() {
        let target = max(0, currentTime - 10)
        seek(to: target)
    }

    func seek(to time: TimeInterval) {
        let dur = useEmbeddedPlayer && outputType == .mpv ? effectiveDuration : duration
        let clamped = min(max(0, time), dur)

        if useEmbeddedPlayer && outputType == .mpv {
            performEmbeddedSeek(to: clamped)
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

    // MARK: Embedded Seeking (WebView)

    private func performEmbeddedSeek(to time: TimeInterval) {
        guard let server = transcodeServer else {
            // No server yet; just update the WebView position if possible.
            let localTime = max(0, time - embeddedSeekOffset)
            hlsWebPlayerCoordinator?.seek(to: localTime)
            embeddedCurrentTime = localTime
            return
        }

        // Allow a small buffer so near-edge seeks don't restart FFmpeg unnecessarily.
        let transcodedUpTo = embeddedSeekOffset + server.currentPosition
        let isBeforeCurrentStream = time < embeddedSeekOffset - 0.5
        let isAfterCurrentStream = time > transcodedUpTo + 2.0
        let isArbitrary = isBeforeCurrentStream || isAfterCurrentStream

        if isArbitrary {
            performEmbeddedArbitrarySeek(to: time, server: server)
        } else {
            performEmbeddedLocalSeek(to: time)
        }
    }

    private func performEmbeddedLocalSeek(to time: TimeInterval) {
        let localTime = max(0, time - embeddedSeekOffset)
        hlsWebPlayerCoordinator?.seek(to: localTime)
        embeddedCurrentTime = localTime
        isArbitrarySeeking = false
    }

    private func performEmbeddedArbitrarySeek(to time: TimeInterval, server: TranscodeServer) {
        isArbitrarySeeking = true
        statusMessage = "Seeking..."
        embeddedCurrentTime = time
        embeddedSeekOffset = time

        // Restart transcoder at target position and reload WebView with cache-busted URL.
        server.seek(to: time, awaitClientReconnect: false)
        let cacheBustedURL = cacheBustURL(server.url)
        hlsWebPlayerCoordinator?.pollAndLoad(url: cacheBustedURL)
    }

    private func cacheBustURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let timestamp = Date().timeIntervalSince1970
        let item = URLQueryItem(name: "t", value: String(format: "%.3f", timestamp))
        if components?.queryItems != nil {
            components?.queryItems?.append(item)
        } else {
            components?.queryItems = [item]
        }
        return components?.url ?? url
    }

    func embeddedPlaybackStarted() {
        isArbitrarySeeking = false
        isStreamReady = true
        statusMessage = "Playing"
    }

    // MARK: Promo Display

    private func showPromoOnChromecast() {
        guard let device = selectedDevice else { return }

        Task {
            do {
                // Start promo image server if not already running
                if promoImageServer == nil {
                    // Use absolute path to the backdrop image in source tree
                    let backdropPath = "/Users/rob/Dev/Beamy/assets/backdrop_1920x1080.jpg"
                    print("[PROMO] Starting image server with path: \(backdropPath)")
                    promoImageServer = try PromoImageServer(imagePath: backdropPath, port: 8081)
                }

                guard let promoServer = promoImageServer else {
                    print("[PROMO] ERROR: promoServer is nil after init")
                    return
                }

                print("[PROMO] Image server URL: \(promoServer.url)")

                // Create and store the client (don't let it disconnect!)
                let client = CastV2Client(device: device, verbose: true)
                try client.connect()
                print("[PROMO] Connected to Chromecast")

                try client.launchDefaultMediaReceiver()
                print("[PROMO] Launched receiver")

                print("[PROMO] Loading media: \(promoServer.url.absoluteString)")
                try client.loadMedia(
                    url: promoServer.url,
                    contentType: "image/jpeg",
                    title: "Beamy McBeamface",
                    isLive: false
                )
                print("[PROMO] Media loaded successfully")

                // Store the client to keep it alive (don't disconnect!)
                await MainActor.run {
                    promoCastClient = client
                }

                await MainActor.run {
                    statusMessage = "Ready - Drop a video file to start"
                }
            } catch {
                print("[PROMO] ERROR: \(error)")
                await MainActor.run {
                    errorMessage = "Failed to show promo: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Cleanup

    private func cleanupPlayer() {
        playerHandle?.cleanup()
        playerHandle = nil
    }

    func stopPlayback() {
        print("DEBUG: stopPlayback() called")
        print("DEBUG: playerHandle exists: \(playerHandle != nil)")
        print("DEBUG: promoCastClient exists before cleanup: \(promoCastClient != nil)")
        cleanupPlayer()
        mpvPlayerCoordinator?.stop()
        mpvPlayerCoordinator = nil
        positionTimer?.invalidate()
        positionTimer = nil
        transcodeServer?.stop()
        transcodeServer = nil
        promoImageServer?.stop()
        promoImageServer = nil
        // Don't disconnect promo client here - let new video client take over the session
        // Disconnecting would stop the receiver since it's the only sender
        print("DEBUG: setting promoCastClient = nil (NOT calling disconnect)")
        promoCastClient = nil
        isStreamReady = false
        lastKnownPosition = 0
        lastKnownPaused = true
        chromecastSeekOffset = 0
        embeddedIsPlaying = false
        embeddedCurrentTime = 0
        embeddedDuration = 0
        embeddedSeekOffset = 0
        currentFile = nil
        mediaInfo = nil
        duration = 0
        statusMessage = "Drop a video file to start"
    }

    /// Stop playback and return to initial state, showing promo on Chromecast if connected
    func stopAndReset() {
        print("DEBUG: stopAndReset() called")

        // Stop current playback
        cleanupPlayer()
        mpvPlayerCoordinator?.stop()
        mpvPlayerCoordinator = nil
        positionTimer?.invalidate()
        positionTimer = nil
        transcodeServer?.stop()
        transcodeServer = nil

        // Reset playback state
        isStreamReady = false
        lastKnownPosition = 0
        lastKnownPaused = true
        chromecastSeekOffset = 0
        embeddedIsPlaying = false
        embeddedCurrentTime = 0
        embeddedDuration = 0
        embeddedSeekOffset = 0
        currentFile = nil
        mediaInfo = nil
        duration = 0

        // If on Chromecast, re-show the promo image
        if outputType == .chromecast, selectedDevice != nil {
            print("DEBUG: Re-showing promo on Chromecast")
            showPromoOnChromecast()
            statusMessage = "Ready - Drop a video file to start"
        } else {
            statusMessage = "Drop a video file to start"
        }
    }

    /// Called when app terminates - stops the receiver to clear Chromecast screen
    func terminatePlayback() {
        // Stop receiver to clear Chromecast screen on quit
        try? promoCastClient?.stopMedia()
        promoCastClient?.disconnect()
        promoCastClient = nil

        cleanupPlayer()
        mpvPlayerCoordinator?.stop()
        mpvPlayerCoordinator = nil
        positionTimer?.invalidate()
        positionTimer = nil
        transcodeServer?.stop()
        transcodeServer = nil
        promoImageServer?.stop()
        promoImageServer = nil
        isStreamReady = false
        lastKnownPosition = 0
        lastKnownPaused = true
        chromecastSeekOffset = 0
        embeddedIsPlaying = false
        embeddedCurrentTime = 0
        embeddedDuration = 0
        embeddedSeekOffset = 0
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
