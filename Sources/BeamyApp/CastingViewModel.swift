import SwiftUI
import BeamyKit
import Combine

// MARK: - Output Type

enum OutputType: String, CaseIterable {
    case mpv = "mpv"
    case chromecast = "chromecast"
    case roku = "roku"
}

// MARK: - Roku Setup Status

enum RokuSetupStatus: Equatable {
    case notSelected
    case checking
    case limitedMode
    case receiverNotInstalled
    case ready

    var message: String? {
        switch self {
        case .notSelected:
            return "Select a Roku device"
        case .checking:
            return "Checking Roku setup..."
        case .limitedMode:
            return "On your Roku: Settings → System → Advanced system settings → Control by mobile apps → Enabled"
        case .receiverNotInstalled:
            return "On your Roku: Channel Store → Find 'Web Video Caster' → Install the Receiver app"
        case .ready:
            return nil
        }
    }

    var canDropVideo: Bool {
        self == .ready
    }
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
    @Published var rokuDevices: [RokuDevice] = []
    @Published var selectedDevice: ChromecastDevice? {
        didSet {
            saveSelectedDevice()
            // Show promo on Chromecast when device selected but no video loaded
            if selectedDevice != nil && outputType == .chromecast && currentFile == nil {
                showPromoOnChromecast()
            }
        }
    }
    @Published var selectedRokuDevice: RokuDevice? {
        didSet {
            // Check Roku setup when device selected
            if selectedRokuDevice != nil && outputType == .roku {
                checkRokuSetup()
            } else if selectedRokuDevice == nil {
                rokuSetupStatus = .notSelected
            }
        }
    }
    @Published var rokuSetupStatus: RokuSetupStatus = .notSelected
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

            // Check Roku setup when switching TO Roku
            if outputType == .roku {
                if selectedRokuDevice != nil {
                    checkRokuSetup()
                } else {
                    rokuSetupStatus = .notSelected
                }
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
    @Published var toastMessage: String?
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
    private var imageServer: ImageServer?
    private var imageStreamServer: ImageStreamServer?  // For Roku promo (image as video)
    private var promoCastClient: CastV2Client?  // Keep promo client alive
    private var rokuPlayer: RokuPlayer?
    private let debugLogURL = URL(fileURLWithPath: "/tmp/beamy-debug.log")

    // Position tracking
    private var lastKnownPosition: TimeInterval = 0
    @Published private var lastKnownPaused: Bool = true
    private var chromecastSeekOffset: TimeInterval = 0
    private var embeddedSeekOffset: TimeInterval = 0
    @Published private var rokuSeekOffset: TimeInterval = 0
    var embeddedPlayerCoordinator: AVPlayerView.Coordinator?
    var mpvPlayerCoordinator: MpvPlayerView.Coordinator?
    var hlsWebPlayerCoordinator: HLSWebPlayerView.Coordinator?

    // MARK: Computed Properties (query Player, not TranscodeServer)

    var isPlaying: Bool {
        // For embedded AVPlayer, use the binding state
        if useEmbeddedPlayer && outputType == .mpv {
            return embeddedIsPlaying
        }
        // For Roku, use lastKnownPaused state (no player handle)
        if outputType == .roku && rokuPlayer != nil {
            return !lastKnownPaused
        }
        guard let player = playerHandle?.player else { return false }
        return !((try? player.isPaused()) ?? true)
    }

    var currentTime: TimeInterval {
        // For embedded AVPlayer, use the binding state
        if useEmbeddedPlayer && outputType == .mpv {
            return embeddedSeekOffset + embeddedCurrentTime
        }
        // For Roku, use seek offset (no position tracking from device)
        if outputType == .roku && rokuPlayer != nil {
            return rokuSeekOffset
        }
        guard let player = playerHandle?.player else { return lastKnownPosition }

        // For Chromecast LIVE streams, add seek offset
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
        // Create/clear debug log
        if !FileManager.default.fileExists(atPath: debugLogURL.path) {
            FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
        }
        debugLog("=== App Started ===")

        isLoadingConfig = true
        loadConfig()
        discoverDevices()
        isLoadingConfig = false
    }

    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: debugLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds
            if toastMessage == message {
                toastMessage = nil
            }
        }
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
            // Discover Chromecast and Roku
            let timeout = (try? Config.load().chromecast.discoveryTimeout) ?? 5.0
            let allDevices = (try? ChromecastDiscovery.discover(timeout: timeout)) ?? []
            let chromecasts = allDevices.filter { $0.isVideoCapable }

            let rokus = await RokuDiscovery.shared.discover(timeout: 3.0)

            await MainActor.run {
                self.devices = chromecasts
                self.rokuDevices = rokus
                self.isDiscovering = false

                // Debug: Show discovered devices
                self.debugLog("[DISCOVERY] Found \(chromecasts.count) Chromecast(s), \(rokus.count) Roku(s)")
                for device in chromecasts {
                    self.debugLog("[DISCOVERY]   - Chromecast: \(device.name) @ \(device.address)")
                }
                for device in rokus {
                    self.debugLog("[DISCOVERY]   - Roku: \(device.name) @ \(device.address)")
                }

                // Restore saved Chromecast device
                if let defaultName = try? Config.load().chromecast.defaultDevice {
                    self.isLoadingConfig = true
                    self.selectedDevice = chromecasts.first { $0.name == defaultName }
                    self.isLoadingConfig = false
                }

                // Auto-select first Roku if none selected
                if self.selectedRokuDevice == nil && !rokus.isEmpty {
                    self.selectedRokuDevice = rokus.first
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

    private func logDebug(_ message: String) {
        let msg = "[\(Date())] \(message)\n"
        if let data = msg.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/beamy-transcoder.log") {
                if let handle = FileHandle(forWritingAtPath: "/tmp/beamy-transcoder.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: "/tmp/beamy-transcoder.log", contents: data)
            }
        }
    }

    /// Called by WebView when it's ready to receive the stream
    func startTranscoderForEmbedded() {
        logDebug("[TRANSCODER] startTranscoderForEmbedded called")
        logDebug("[TRANSCODER] useEmbeddedPlayer=\(useEmbeddedPlayer), outputType=\(outputType)")
        guard useEmbeddedPlayer && outputType == .mpv else {
            logDebug("[TRANSCODER] GUARD FAILED: wrong mode")
            return
        }
        guard transcodeServer == nil else {
            logDebug("[TRANSCODER] GUARD FAILED: transcodeServer already exists")
            return
        }
        guard let url = currentFile, let info = mediaInfo else {
            logDebug("[TRANSCODER] GUARD FAILED: no file or mediaInfo")
            return
        }

        logDebug("[TRANSCODER] Starting transcoder for file: \(url.path)")
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
                    request.httpMethod = "GET"  // GET to check actual content
                    request.timeoutInterval = 2
                    let (data, response) = try await URLSession.shared.data(for: request)

                    if let httpResponse = response as? HTTPURLResponse {
                        print("DEBUG: pollForStreamReady attempt \(attempts) - status \(httpResponse.statusCode)")
                        if httpResponse.statusCode == 200 {
                            // Check if m3u8 has actual segments (not just header)
                            if let content = String(data: data, encoding: .utf8),
                               content.contains(".ts") || content.contains(".m4s") {
                                print("DEBUG: m3u8 has segments, stream is truly ready")
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
                                    }
                                    // Auto-start Roku playback when stream is ready
                                    else if self.outputType == .roku && self.selectedRokuDevice != nil {
                                        self.debugLog("[ROKU] Auto-starting Roku playback")
                                        Task {
                                            do {
                                                try await self.launchPlayer(output: .roku, seekTo: 0, paused: false)
                                                self.debugLog("[ROKU] Playback started successfully")
                                            } catch {
                                                self.debugLog("[ROKU] ERROR: \(error)")
                                                self.errorMessage = "Failed to cast to Roku: \(error.localizedDescription)"
                                            }
                                        }
                                    } else {
                                        print("DEBUG: NOT auto-starting - conditions not met")
                                    }
                                }
                                return
                            } else {
                                print("DEBUG: m3u8 returned 200 but no segments yet")
                            }
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

    // MARK: Position Timer (250ms polling)

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

        // If switching to Roku but no device selected, don't switch yet
        if newOutput == .roku && selectedRokuDevice == nil {
            outputType = newOutput
            statusMessage = "Select a Roku device"
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

        case .roku:
            guard let device = selectedRokuDevice else {
                throw PlayerError.disconnected
            }
            try await launchRoku(device: device, server: server)
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

        // Validate device has valid address
        guard device.hasValidAddress else {
            throw CastV2Error.invalidAddress
        }

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

    // MARK: Roku Setup Check

    func checkRokuSetup() {
        guard let device = selectedRokuDevice else {
            rokuSetupStatus = .notSelected
            return
        }

        rokuSetupStatus = .checking
        debugLog("[ROKU] Checking setup for \(device.name)...")

        Task {
            let player = RokuPlayer(device: device)

            // Check 1: Is ECP enabled (not in Limited Mode)?
            if await player.checkLimitedMode() {
                await MainActor.run {
                    rokuSetupStatus = .limitedMode
                    debugLog("[ROKU] Setup check: Limited Mode detected")
                }
                return
            }

            // Check 2: Is Web Video Caster Receiver installed?
            if !(await player.checkWebVideoCasterInstalled()) {
                await MainActor.run {
                    rokuSetupStatus = .receiverNotInstalled
                    debugLog("[ROKU] Setup check: Web Video Caster not installed")
                }
                return
            }

            // All checks passed
            await MainActor.run {
                rokuSetupStatus = .ready
                debugLog("[ROKU] Setup check: Ready!")
                // Show promo now that setup is complete
                if currentFile == nil {
                    showPromoOnRoku()
                }
            }
        }
    }

    private func launchRoku(device: RokuDevice, server: TranscodeServer) async throws {
        debugLog("[ROKU] Casting to \(device.name) at \(device.address)")
        debugLog("[ROKU] Stream URL: \(server.url)")

        let player = RokuPlayer(device: device)
        let title = currentFile?.lastPathComponent ?? "Beamy Stream"

        debugLog("[ROKU] Sending cast request...")
        try await player.cast(url: server.url, name: title)

        self.rokuPlayer = player
        self.lastKnownPaused = false
        self.rokuSeekOffset = 0
        statusMessage = "Casting to \(device.name)"
        debugLog("[ROKU] Cast successful!")
    }

    // MARK: Playback Controls

    func togglePlayPause() {
        // Embedded HLS WebView path
        if useEmbeddedPlayer && outputType == .mpv {
            hlsWebPlayerCoordinator?.togglePause()
            return
        }

        // Roku path - uses ECP keypress
        if outputType == .roku, let player = rokuPlayer {
            Task {
                do {
                    try await player.playPause()
                    await MainActor.run {
                        lastKnownPaused.toggle()
                        debugLog("[ROKU] Play/Pause sent, now \(lastKnownPaused ? "paused" : "playing")")
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "Roku control error: \(error.localizedDescription)"
                    }
                }
            }
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

            // For Roku, need device selected
            if outputType == .roku && selectedRokuDevice == nil {
                statusMessage = "Select a Roku device first"
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
        // Roku uses ECP keypress for skip (no precise seek)
        if outputType == .roku, let player = rokuPlayer {
            Task {
                do {
                    try await player.fastForward()
                    debugLog("[ROKU] Fast forward sent")
                } catch {
                    await MainActor.run {
                        errorMessage = "Roku control error: \(error.localizedDescription)"
                    }
                }
            }
            return
        }
        let target = currentTime + 10
        seek(to: target)
    }

    func skipBackward() {
        // Roku uses ECP keypress for skip (no precise seek)
        if outputType == .roku, let player = rokuPlayer {
            Task {
                do {
                    try await player.rewind()
                    debugLog("[ROKU] Rewind sent")
                } catch {
                    await MainActor.run {
                        errorMessage = "Roku control error: \(error.localizedDescription)"
                    }
                }
            }
            return
        }
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

        // Roku seek - restart transcode at new position and recast
        if outputType == .roku, let player = rokuPlayer, let server = transcodeServer {
            rokuSeekOffset = clamped  // Update immediately for UI
            Task {
                do {
                    debugLog("[ROKU] Seeking to \(clamped)s - restarting stream")
                    server.seek(to: clamped, awaitClientReconnect: true)
                    let title = currentFile?.lastPathComponent ?? "Beamy Stream"
                    try await player.recast(url: server.url, name: title)  // Skip receiver launch
                    await MainActor.run {
                        lastKnownPaused = false  // Roku resumes playing after recast
                        debugLog("[ROKU] Seek complete, now playing")
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "Roku seek error: \(error.localizedDescription)"
                    }
                }
            }
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
        embeddedCurrentTime = 0  // Reset - new stream starts at 0
        embeddedSeekOffset = time  // Offset tracks the seek position

        // Immediately pause to freeze current frame
        hlsWebPlayerCoordinator?.pause()

        // Restart transcoder at target position and reload WebView with cache-busted URL.
        server.seek(to: time, awaitClientReconnect: false)
        let cacheBustedURL = cacheBustURL(server.url)
        hlsWebPlayerCoordinator?.forcePollAndLoad(url: cacheBustedURL)
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
        guard let device = selectedDevice else {
            debugLog("[PROMO] No device selected, skipping promo")
            return
        }

        debugLog("[PROMO] showPromoOnChromecast() called for device: \(device.name)")

        // Check if device has valid address, trigger re-discovery if not
        guard device.hasValidAddress else {
            debugLog("[PROMO] Device has EMPTY address, triggering re-discovery")
            statusMessage = "Re-discovering device..."
            discoverDevices()
            return
        }

        debugLog("[PROMO] Device has address: \(device.address), attempting connection...")

        Task {
            do {
                // Start promo image server if not already running
                if imageServer == nil {
                    // Use absolute path to the backdrop image in source tree
                    guard let backdropPath = Bundle.main.path(forResource: "backdrop_1920x1080", ofType: "jpg") else {
                        print("[PROMO] ERROR: backdrop image not found in bundle")
                        return
                    }
                    print("[PROMO] Starting image server with path: \(backdropPath)")
                    imageServer = try ImageServer(imagePath: backdropPath, port: 8081)
                }

                guard let promoServer = imageServer else {
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

    private func showPromoOnRoku() {
        guard let device = selectedRokuDevice else {
            debugLog("[ROKU-PROMO] No Roku device selected")
            return
        }

        debugLog("[ROKU-PROMO] Showing promo on \(device.name)")
        statusMessage = "Connecting to \(device.name)..."

        Task {
            do {
                // Start image stream server (converts image to HLS video)
                if imageStreamServer == nil {
                    guard let backdropPath = Bundle.main.path(forResource: "backdrop_1920x1080", ofType: "jpg") else {
                        debugLog("[ROKU-PROMO] ERROR: backdrop image not found in bundle")
                        await MainActor.run {
                            statusMessage = "Ready - Drop a video to cast to \(device.name)"
                        }
                        return
                    }
                    debugLog("[ROKU-PROMO] Starting image stream server")
                    imageStreamServer = try ImageStreamServer(imagePath: backdropPath, port: 8082)

                    // Wait for FFmpeg to generate initial segments
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }

                guard let streamServer = imageStreamServer else {
                    debugLog("[ROKU-PROMO] ERROR: streamServer is nil")
                    return
                }

                debugLog("[ROKU-PROMO] Stream URL: \(streamServer.url)")

                // Cast the HLS stream to Roku
                let player = RokuPlayer(device: device)
                try await player.cast(url: streamServer.url, name: "Beamy McBeamface")

                self.rokuPlayer = player
                debugLog("[ROKU-PROMO] Promo cast successful!")

                await MainActor.run {
                    statusMessage = "Ready - Drop a video to cast to \(device.name)"
                }
            } catch RokuError.limitedMode {
                // Limited Mode - show helpful error to user
                debugLog("[ROKU-PROMO] ERROR: Limited Mode detected")
                await MainActor.run {
                    errorMessage = RokuError.limitedMode.localizedDescription
                    statusMessage = "Roku blocked - see error above"
                }
            } catch {
                debugLog("[ROKU-PROMO] ERROR: \(error)")
                await MainActor.run {
                    // Other errors - show the error
                    errorMessage = "Roku: \(error.localizedDescription)"
                    statusMessage = "Ready - Drop a video to cast to \(device.name)"
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
        imageServer?.stop()
        imageServer = nil
        imageStreamServer?.stop()
        imageStreamServer = nil
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
        imageServer?.stop()
        imageServer = nil
        imageStreamServer?.stop()
        imageStreamServer = nil
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
