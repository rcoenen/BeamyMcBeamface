import Foundation
import BeamyKit
@preconcurrency import TermKit

/// A TermKit-based UI for controlling playback via the Player abstraction.
/// Keeps the existing CLI flags; opt-in via `--termkit` in TranscodeTest.
private final class PlayerToplevel: Toplevel {
    var handleKey: ((KeyEvent) -> Bool)?

    override func processKey(event: KeyEvent) -> Bool {
        if let handler = handleKey, handler(event) {
            return true
        }
        return super.processKey(event: event)
    }
}

final class TermKitTranscoderUI {
    enum OutputChoice: Int {
        case mpv = 0
        case chromecast = 1
    }

    private struct PlayerHandle {
        let output: OutputChoice
        let player: Player
        let cleanup: () -> Void
    }

    enum DiscoveryState {
        case idle
        case scanning(started: Date)
        case completed(devices: [ChromecastDevice], timestamp: Date)
    }

    private let server: TranscodeServer
    private let duration: TimeInterval
    private let title: String
    private var config: Config
    private var selectedOutput: OutputChoice?
    private let onCleanup: (() -> Void)?
    private weak var toplevel: Toplevel?
    private var playerHandle: PlayerHandle?
    private var lastKnownPosition: TimeInterval = 0
    private var lastKnownPaused: Bool = true
    private var timer: DispatchSourceTimer?
    private var isLaunching: Bool = false
    private let logURL = URL(fileURLWithPath: "/tmp/beamy-tui.log")
    private weak var spinnerDialog: Dialog?
    private var selectedChromecastName: String?
    private var outputRadio: RadioGroup?
    private var outputFrame: Frame?
    private weak var chromecastButton: Button?

    // Discovery state with thread-safe access
    private let discoveryQueue = DispatchQueue(label: "com.beamy.discovery", qos: .userInitiated)
    private var _discoveryState: DiscoveryState = .idle
    private var discoveryState: DiscoveryState {
        get { discoveryQueue.sync { _discoveryState } }
        set { discoveryQueue.sync { _discoveryState = newValue } }
    }

    // Output switching state
    private var isSwitchingOutput = false

    // Position polling state
    private var lastPositionPollTime: Date?
    private var lastSeekTime: Date?

    init(
        server: TranscodeServer,
        duration: TimeInterval,
        title: String,
        config: Config,
        initialOutput: OutputChoice? = nil,
        onCleanup: (() -> Void)? = nil
    ) {
        self.server = server
        self.duration = duration
        self.title = title
        self.config = config
        // Choose initial selection: explicit override > config.ui.defaultOutput > none
        if let initialOutput {
            self.selectedOutput = initialOutput
        } else if let saved = config.ui.defaultOutput?.lowercased() {
            switch saved {
            case "mpv": self.selectedOutput = .mpv
            case "chromecast": self.selectedOutput = .chromecast
            default: self.selectedOutput = nil
            }
        } else {
            self.selectedOutput = nil
        }
        self.onCleanup = onCleanup
    }

    func run() throws {
        resetLog()
        log("=== TermKit UI start ===")
        let initial = selectedOutput.map { $0 == .mpv ? "mpv" : "chromecast" } ?? "none"
        log("Initial output selection: \(initial) (config ui.defaultOutput=\(config.ui.defaultOutput ?? "nil"))")

        Application.prepare(driverType: .curses)

        let top = PlayerToplevel()
        top.fill()
        self.toplevel = top

        let window = Window("Beamy Player (TermKit)")
        window.x = Pos.at(0)
        window.y = Pos.at(0)
        window.width = Dim.fill()
        window.height = Dim.fill()

        // Output selector container
        let outputFrame = Frame("Output")
        self.outputFrame = outputFrame
        outputFrame.x = Pos.at(1)
        outputFrame.y = Pos.at(1)
        // Size to fit the longest label plus padding/border.
        outputFrame.width = Dim.sized(40)
        outputFrame.height = Dim.sized(6)

        // Load saved Chromecast device if available
        if let saved = config.chromecast.defaultDevice {
            selectedChromecastName = saved
        } else {
            // If Chromecast was selected but there's no device, force to mpv
            if selectedOutput == .chromecast {
                log("No Chromecast device configured - forcing output to mpv")
                selectedOutput = .mpv
            }
        }

        let chromecastButton = Button("Select Chromecast…")
        chromecastButton.x = Pos.at(1)
        chromecastButton.y = Pos.bottom(of: outputFrame) + 1
        chromecastButton.width = Dim.sized(24)
        chromecastButton.colorScheme = makeScheme(
            normalFore: .black, normalBack: .brightCyan,
            focusFore: .black, focusBack: .white
        )
        chromecastButton.canFocus = true
        self.chromecastButton = chromecastButton

        let statusLabel = Label("Status: idle (choose output, press Play)")
        statusLabel.x = Pos.at(1)
        statusLabel.y = Pos.bottom(of: chromecastButton) + 1

        chromecastButton.clicked = { [weak self, weak statusLabel] _ in
            guard let self else { return }
            self.applyOutputChoice(.chromecast, statusLabel: statusLabel, forcePicker: true)
        }

        // Build initial radio with dynamic labels (only shows Chromecast if device configured)
        // Note: selectionChanged handler is set by rebuildOutputRadio()
        rebuildOutputRadio(chromecastName: selectedChromecastName, selected: selectedOutput?.rawValue, statusLabel: statusLabel)

        let timeLabel = Label("Time: --:--:-- / \(formatTime(duration))")
        timeLabel.x = Pos.at(1)
        timeLabel.y = Pos.bottom(of: statusLabel) + 1

        let percentLabel = Label("Progress: 0%")
        percentLabel.x = Pos.at(1)
        percentLabel.y = Pos.bottom(of: timeLabel) + 1

        let barLabel = Label(" \(formatTime(0)) [] \(formatTime(duration))")
        barLabel.x = Pos.at(1)
        barLabel.y = Pos.bottom(of: percentLabel) + 1
        barLabel.width = Dim.fill() - Dim.sized(2)

        let playPauseButton = Button("Play/Pause")
        playPauseButton.x = Pos.at(1)
        playPauseButton.y = Pos.bottom(of: barLabel) + 1
        playPauseButton.width = Dim.sized(14)
        playPauseButton.isDefault = false
        playPauseButton.colorScheme = makeScheme(
            normalFore: .black, normalBack: .brightGreen,
            focusFore: .black, focusBack: .white
        )
        playPauseButton.clicked = { [weak self, weak statusLabel] _ in
            self?.handlePlayPause(statusLabel: statusLabel)
        }

        let seekBackButton = Button("⟵ 10s")
        seekBackButton.x = Pos.right(of: playPauseButton) + 2
        seekBackButton.y = playPauseButton.y
        seekBackButton.width = Dim.sized(10)
        seekBackButton.colorScheme = makeScheme(
            normalFore: .black, normalBack: .brightCyan,
            focusFore: .black, focusBack: .white
        )
        seekBackButton.clicked = { [weak self, weak statusLabel] _ in
            self?.scrub(by: -10, statusLabel: statusLabel)
        }

        let seekForwardButton = Button("10s ⟶")
        seekForwardButton.x = Pos.right(of: seekBackButton) + 2
        seekForwardButton.y = playPauseButton.y
        seekForwardButton.width = Dim.sized(10)
        seekForwardButton.colorScheme = makeScheme(
            normalFore: .black, normalBack: .brightCyan,
            focusFore: .black, focusBack: .white
        )
        seekForwardButton.clicked = { [weak self, weak statusLabel] _ in
            self?.scrub(by: 10, statusLabel: statusLabel)
        }

        let quitButton = Button("Quit")
        quitButton.x = Pos.right(of: seekForwardButton) + 2
        quitButton.y = playPauseButton.y
        quitButton.width = Dim.sized(8)
        quitButton.colorScheme = makeScheme(
            normalFore: .white, normalBack: .red,
            focusFore: .white, focusBack: .brightMagenta
        )
        quitButton.clicked = { [weak self] _ in
            self?.cleanupCurrentPlayer()
            self?.onCleanup?()
            Application.requestStop()
        }

        let jumpLabel = Label("Jump to (s or hh:mm:ss):")
        jumpLabel.x = Pos.at(1)
        jumpLabel.y = Pos.bottom(of: playPauseButton) + 1

        let jumpField = TextField("")
        jumpField.x = Pos.right(of: jumpLabel) + 1
        jumpField.y = jumpLabel.y
        // Compact entry (seconds or hh:mm:ss). Narrow to avoid huge bar.
        jumpField.width = Dim.sized(10)

        let jumpButton = Button("Jump")
        jumpButton.x = Pos.right(of: jumpField) + 1
        jumpButton.y = jumpLabel.y
        jumpButton.width = Dim.sized(8)
        jumpButton.colorScheme = makeScheme(
            normalFore: .black, normalBack: .brightGreen,
            focusFore: .black, focusBack: .white
        )
        jumpButton.clicked = { [weak self, weak statusLabel, weak jumpField] _ in
            guard let self = self else { return }
            let text = jumpField?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let target = self.parseTime(text) else {
                statusLabel?.text = "Status: invalid time '\(text)'"
                return
            }
            self.seekTo(target, statusLabel: statusLabel)
        }

        window.addSubview(outputFrame)
        window.addSubview(chromecastButton)
        window.addSubview(statusLabel)
        window.addSubview(timeLabel)
        window.addSubview(percentLabel)
        window.addSubview(barLabel)
        window.addSubview(playPauseButton)
        window.addSubview(seekBackButton)
        window.addSubview(seekForwardButton)
        window.addSubview(quitButton)
        window.addSubview(jumpLabel)
        window.addSubview(jumpField)
        window.addSubview(jumpButton)
        let shortcutsLabel = Label("Keys: J=Jump  Q=Quit")
        shortcutsLabel.x = Pos.at(1)
        shortcutsLabel.y = Pos.bottom(of: jumpField) + 1
        window.addSubview(shortcutsLabel)

        top.addSubview(window)
        Application.top.addSubview(top)

        top.handleKey = { [weak self, weak jumpField, weak statusLabel] event in
            guard let self = self else { return false }
            // Only handle global shortcuts (J, Q) - let TermKit handle all navigation (UP/DOWN/TAB)
            switch event.key {
            case .letter(let ch):
                switch ch {
                case "q", "Q":
                    self.cleanupCurrentPlayer()
                    self.onCleanup?()
                    Application.requestStop()
                    return true
                case "j", "J":
                    self.focusAndJump(jumpField: jumpField, statusLabel: statusLabel)
                    return true
                default:
                    return false
                }
            default:
                return false
            }
        }

        startTimer(statusLabel: statusLabel, timeLabel: timeLabel, percentLabel: percentLabel, barLabel: barLabel)

        // Start background Chromecast discovery
        startBackgroundDiscovery()

        Application.run()
        timer?.cancel()
        cleanupCurrentPlayer()
        onCleanup?()
    }

    private func startTimer(statusLabel: Label, timeLabel: Label, percentLabel: Label, barLabel: Label) {
        // Run on the main queue so TermKit views are only touched from one thread.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self, weak statusLabel, weak timeLabel, weak percentLabel] in
            guard let self = self else { return }
            guard let player = self.playerHandle?.player else {
                statusLabel?.text = "Status: idle (choose output, press Play)"
                timeLabel?.text = "Time: \(self.formatTime(self.lastKnownPosition)) / \(self.formatTime(self.duration))"
                percentLabel?.text = "Progress: 0%"
                barLabel.text = self.makeBarText(position: self.lastKnownPosition)
                return
            }

            let position: TimeInterval
            if let p = try? player.getPosition() {
                position = p
                self.lastKnownPosition = p
            } else if let mpv = player as? MpvPlayer {
                position = mpv.extrapolatedPosition()
                self.lastKnownPosition = position
            } else {
                position = self.lastKnownPosition
            }

            let paused = (try? player.isPaused()) ?? self.lastKnownPaused
            self.lastKnownPaused = paused

            // Poll Chromecast for fresh position every 1s during playback
            if let chromecastPlayer = player as? ChromecastPlayer, !paused {
                let now = Date()
                let shouldPoll = self.lastPositionPollTime == nil || now.timeIntervalSince(self.lastPositionPollTime!) >= 1.0
                if shouldPoll {
                    try? chromecastPlayer.requestPositionUpdate()
                    self.lastPositionPollTime = now
                }
            }

            // Detect position drift between server and player
            let serverPosition = self.server.currentPosition
            let drift = abs(serverPosition - position)
            // Skip drift detection if seek occurred within last 2s
            let recentSeek = self.lastSeekTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false
            if !recentSeek && drift > 3.0 {
                self.log("Position drift detected: server \(serverPosition)s, player \(position)s (drift: \(drift)s)")
            }

            let percent = self.duration > 0 ? (position / self.duration) * 100 : 0
            let outputName = (self.selectedOutput == .mpv) ? "mpv" : "Chromecast"
            statusLabel?.text = "Status: \(paused ? "paused" : "playing") via \(outputName)"
            timeLabel?.text = "Time: \(self.formatTime(position)) / \(self.formatTime(self.duration))"
            percentLabel?.text = "Progress: \(Int(round(percent)))%"
            barLabel.text = self.makeBarText(position: position)
        }
        self.timer = timer
        timer.resume()
    }

    private func handlePlayPause(statusLabel: Label?) {
        ensurePlayerAvailable(statusLabel: statusLabel) { [weak self] ready in
            guard ready, let self = self, let player = self.playerHandle?.player else { return }
            do {
                let paused = (try? player.isPaused()) ?? self.lastKnownPaused
                if paused {
                    try player.resume()
                    self.lastKnownPaused = false
                    statusLabel?.text = "Status: playing via \(self.selectedOutput == .mpv ? "mpv" : "Chromecast")"
                } else {
                    try player.pause()
                    self.lastKnownPaused = true
                    statusLabel?.text = "Status: paused"
                }
            } catch {
                statusLabel?.text = "Status: error \(error)"
            }
        }
    }

    private func ensurePlayerAvailable(statusLabel: Label?, completion: @escaping @Sendable (Bool) -> Void) {
        if isLaunching {
            statusLabel?.text = "Status: launching..."
            completion(false)
            return
        }

        if let handle = playerHandle, handle.output == selectedOutput {
            completion(true)
            return
        }

        guard let output = selectedOutput else {
            statusLabel?.text = "Status: select an output first"
            isLaunching = false
            completion(false)
            return
        }

        isLaunching = true
        cleanupCurrentPlayer()

        switch output {
        case .mpv:
            do {
                statusLabel?.text = "Status: starting mpv..."
                let handle = try launchMpv()
                playerHandle = handle
                lastKnownPaused = false
                completion(true)
            } catch {
                statusLabel?.text = "Status: mpv error \(error)"
                completion(false)
            }
            isLaunching = false
        case .chromecast:
            resolveChromecastDevice(statusLabel: statusLabel) { [weak self, weak statusLabel] device in
                guard let self else { return }
                self.isLaunching = false
                guard let device else {
                    completion(false)
                    return
                }
                do {
                    let handle = try self.launchChromecast(to: device)
                    self.playerHandle = handle
                    self.lastKnownPaused = false
                    // Persist chosen device.
                    self.config.chromecast.defaultDevice = device.name
                    try? self.config.save()
                    self.persistDefaultOutput(.chromecast)
                    self.selectedChromecastName = device.name
                    statusLabel?.text = "Status: Chromecast set to \(device.name)"
                    completion(true)
                } catch {
                    statusLabel?.text = "Status: Chromecast error \(error)"
                    completion(false)
                }
            }
            return
        }
        isLaunching = false
    }

    private func launchMpv() throws -> PlayerHandle {
        log("Launching mpv at \(server.url.absoluteString)")
        let controller = MpvController()
        _ = try controller.launch(url: server.url, windowTitle: "Beamy Player (mpv)")
        let player = MpvPlayer(controller: controller, server: server, streamURL: server.url)
        if lastKnownPosition > 0 {
            try? player.seek(to: lastKnownPosition)
        }
        if lastKnownPaused {
            try? player.pause()
        }

        // Validate position after output switch
        if lastKnownPosition > 0, let actualPosition = try? player.getPosition() {
            let drift = abs(actualPosition - lastKnownPosition)
            if drift > 2.0 {
                log("Position drift after switch to mpv: expected \(lastKnownPosition)s, got \(actualPosition)s (drift: \(drift)s)")
            }
        }

        return PlayerHandle(output: .mpv, player: player, cleanup: {
            controller.quit()
        })
    }

    private func launchChromecast(to device: ChromecastDevice) throws -> PlayerHandle {
        log("Launching Chromecast to \(device.name) addr=\(device.address):\(device.port) model=\(device.model ?? "unknown") type=\(device.castType.rawValue)")
        let client = CastV2Client(device: device, verbose: true)
        try client.connect()
        try client.launchDefaultMediaReceiver()
        try client.loadMedia(url: server.url, contentType: "video/x-matroska", title: title, isLive: true)
        let player = ChromecastPlayer(client: client)
        if lastKnownPosition > 0 {
            try? player.seek(to: lastKnownPosition)
        }
        if lastKnownPaused {
            try? player.pause()
        }

        // Validate position after output switch
        if lastKnownPosition > 0, let actualPosition = try? player.getPosition() {
            let drift = abs(actualPosition - lastKnownPosition)
            if drift > 2.0 {
                log("Position drift after switch to Chromecast: expected \(lastKnownPosition)s, got \(actualPosition)s (drift: \(drift)s)")
            }
        }

        return PlayerHandle(output: .chromecast, player: player, cleanup: {
            client.disconnect()
        })
    }

    private func resolveChromecastDevice(statusLabel: Label?, completion: @escaping @Sendable (ChromecastDevice?) -> Void) {
        let timeout = config.chromecast.discoveryTimeout
        if let preferred = config.chromecast.defaultDevice {
            statusLabel?.text = "Status: checking Chromecast \(preferred)..."
            log("Resolving preferred Chromecast from config: \(preferred) with timeout \(timeout)s")
            let device = try? ChromecastDiscovery.findDevice(named: preferred, timeout: timeout)
            if let device {
                log("Preferred Chromecast found: \(device.name) model=\(device.model ?? "unknown") type=\(device.castType.rawValue)")
                completion(device)
            } else {
                log("Preferred Chromecast \(preferred) not found; falling back to discovery dialog")
                presentDiscovery(statusLabel: statusLabel, timeout: timeout, completion: completion)
            }
        } else {
            log("No preferred Chromecast set; starting discovery dialog")
            presentDiscovery(statusLabel: statusLabel, timeout: timeout, completion: completion)
        }
    }

    private func validateConfiguredDevice(against devices: [ChromecastDevice]) {
        guard let configured = selectedChromecastName else { return }

        // Check if configured device exists in discovered devices
        let exists = devices.contains(where: { $0.name == configured })

        if !exists {
            log("Configured device '\(configured)' not found in discovery - clearing configuration")
            // Clear configuration across all three representations
            selectedChromecastName = nil
            config.chromecast.defaultDevice = nil
            try? config.save()
            rebuildOutputRadio(chromecastName: nil, selected: outputRadio?.selected, statusLabel: nil)
        }
    }

    private func startBackgroundDiscovery() {
        // Check if already scanning or have recent results
        switch discoveryState {
        case .scanning:
            log("Discovery already in progress - skipping duplicate scan")
            return
        case .completed(_, let timestamp) where Date().timeIntervalSince(timestamp) < 30:
            log("Using recent discovery results (age: \(Int(Date().timeIntervalSince(timestamp)))s)")
            return
        case .idle, .completed:
            break
        }

        log("Starting background Chromecast discovery")
        discoveryState = .scanning(started: Date())

        let timeout = config.chromecast.discoveryTimeout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let devices = (try? ChromecastDiscovery.discover(timeout: timeout)) ?? []
            self.log("Background discovery complete (\(devices.count) total devices)")
            for device in devices {
                self.log("  - \(device.name) model=\(device.model ?? "unknown") type=\(device.castType.rawValue)")
            }

            let videoDevices = devices.filter { $0.isVideoCapable }
            self.log("Background discovery: \(videoDevices.count) video-capable devices")

            DispatchQueue.main.async {
                self.handleDiscoveryComplete(devices: videoDevices)
            }
        }
    }

    private func handleDiscoveryComplete(devices: [ChromecastDevice]) {
        log("Handling discovery completion with \(devices.count) video-capable devices")
        discoveryState = .completed(devices: devices, timestamp: Date())

        // Auto-invalidate configured device if not found
        autoInvalidateConfiguredDevice(devices: devices)
    }

    private func autoInvalidateConfiguredDevice(devices: [ChromecastDevice]) {
        guard let configured = selectedChromecastName else {
            // No device configured, nothing to invalidate
            return
        }

        let exists = devices.contains(where: { $0.name == configured })

        if !exists {
            log("Background discovery: '\(configured)' not found - auto-invalidating")

            // Update all three representations
            selectedChromecastName = nil
            selectedOutput = .mpv
            outputRadio?.selected = OutputChoice.mpv.rawValue
            config.chromecast.defaultDevice = nil
            try? config.save()
            rebuildOutputRadio(chromecastName: nil, selected: OutputChoice.mpv.rawValue, statusLabel: nil)
        } else {
            log("Background discovery: '\(configured)' found and validated")
        }
    }

    private func presentDiscovery(statusLabel: Label?, timeout: Double, completion: @escaping @Sendable (ChromecastDevice?) -> Void) {
        // Check discovery state and reuse results if available
        switch discoveryState {
        case .completed(let devices, let timestamp):
            // Use cached results
            let age = Int(Date().timeIntervalSince(timestamp))
            log("Using cached discovery results (age: \(age)s, \(devices.count) devices)")
            statusLabel?.text = "Status: using cached results (\(age)s old)"
            showDiscoveryDialog(devices: devices, timeout: timeout, statusLabel: statusLabel, completion: completion)

        case .scanning(let started):
            // Discovery already in progress - wait for it
            let elapsed = Int(Date().timeIntervalSince(started))
            log("Discovery already in progress (elapsed: \(elapsed)s) - waiting for completion")
            showSpinner(message: "Scanning for Chromecasts…")
            statusLabel?.text = "Status: scanning for devices..."

            // Wait for discovery to complete
            waitForDiscoveryCompletion { [weak self, weak statusLabel] devices in
                guard let self else { return }
                self.hideSpinner()
                statusLabel?.text = "Status: found \(devices.count) video-capable Chromecast(s)"
                self.showDiscoveryDialog(devices: devices, timeout: timeout, statusLabel: statusLabel, completion: completion)
            }

        case .idle:
            // Start fresh discovery
            log("Starting fresh discovery for modal")
            showSpinner(message: "Scanning for Chromecasts…")
            statusLabel?.text = "Status: discovering Chromecast devices..."
            discoveryState = .scanning(started: Date())

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak statusLabel, completion] in
                guard let self else { return }
                let devices = (try? ChromecastDiscovery.discover(timeout: timeout)) ?? []
                self.log("Modal discovery complete (\(devices.count) total):")
                for device in devices {
                    self.log("  - \(device.name) model=\(device.model ?? "unknown") type=\(device.castType.rawValue) addr=\(device.address):\(device.port)")
                }
                let videoDevices = devices.filter { $0.isVideoCapable }

                DispatchQueue.main.async {
                    self.hideSpinner()
                    self.discoveryState = .completed(devices: videoDevices, timestamp: Date())

                    // Validate configured device against discovered devices
                    self.validateConfiguredDevice(against: videoDevices)

                    if videoDevices.isEmpty {
                        statusLabel?.text = "Status: no video-capable Chromecasts found"
                        self.log("Modal discovery: 0 video-capable (found \(devices.count) total)")
                        completion(nil)
                        return
                    }
                    let names = videoDevices.map { "\($0.name) (\($0.model ?? "unknown"))" }.joined(separator: ", ")
                    self.log("Modal discovery: \(videoDevices.count) video-capable -> [\(names)]")
                    statusLabel?.text = "Status: found \(videoDevices.count) video-capable Chromecast(s)"
                    self.showDiscoveryDialog(devices: videoDevices, timeout: timeout, statusLabel: statusLabel, completion: completion)
                }
            }
        }
    }

    private func waitForDiscoveryCompletion(completion: @escaping ([ChromecastDevice]) -> Void) {
        // Poll discovery state until it completes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let startWait = Date()
            let maxWait: TimeInterval = 10.0 // 10 second timeout

            while Date().timeIntervalSince(startWait) < maxWait {
                switch self.discoveryState {
                case .completed(let devices, _):
                    // Discovery completed - return results
                    DispatchQueue.main.async {
                        completion(devices)
                    }
                    return
                case .scanning:
                    // Still scanning - wait a bit
                    Thread.sleep(forTimeInterval: 0.1)
                case .idle:
                    // Unexpected state - discovery was cancelled?
                    self.log("Warning: Discovery state became idle while waiting")
                    DispatchQueue.main.async {
                        completion([])
                    }
                    return
                }
            }

            // Timeout
            self.log("Warning: Timed out waiting for discovery completion")
            DispatchQueue.main.async {
                completion([])
            }
        }
    }

    private func showSpinner(message: String) {
        // Dismiss any existing spinner.
        hideSpinner()
        let dialog = Dialog(title: "", width: 40, height: 5, buttons: [])
        dialog.modal = false
        dialog.closeClicked = nil

        let spinner = Spinner()
        spinner.x = Pos.at(1)
        spinner.y = Pos.at(1)
        dialog.addSubview(spinner)

        let label = Label(message)
        label.x = Pos.right(of: spinner) + 1
        label.y = spinner.y
        dialog.addSubview(label)

        spinner.start()
        spinnerDialog = dialog
        toplevel?.addSubview(dialog)
    }

    private func hideSpinner() {
        guard let dialog = spinnerDialog else { return }
        dialog.superview?.removeSubview(dialog)
        spinnerDialog = nil
    }

    private func showDiscoveryDialog(
        devices: [ChromecastDevice],
        timeout: Double,
        statusLabel: Label?,
        completion: @escaping @Sendable (ChromecastDevice?) -> Void
    ) {
        var currentDevices = devices
        log("Opening Chromecast dialog with \(currentDevices.count) video devices")
        let width = min(max(50, currentDevices.map { $0.name.count }.max() ?? 0 + 10), 80)
        let listHeight = min(10, max(3, currentDevices.count))
        let height = min(25, listHeight + 5) // list rows + buttons/title padding
        let dialog = Dialog(title: "Select Chromecast", width: width, height: height, buttons: [])
        dialog.modal = true
        dialog.closeClicked = nil
        dialog.closedCallback = { [weak self] in
            self?.log("Chromecast dialog closed without selection")
            completion(nil)
        }

        // Build options: include "None" to disable Chromecast.
        func buildLabels() -> ([ChromecastDevice?], [String], Int) {
            var options: [ChromecastDevice?] = [nil]
            options.append(contentsOf: currentDevices)
            let labels: [String] = options.map { device in
                if let device {
                    // Checkmark shows CONFIGURED device, not currently playing device
                    let isActive = (device.name == self.selectedChromecastName)
                    let prefix = isActive ? "✓ " : "  "
                    return "\(prefix)📺 \(device.name)"
                } else {
                    // "None" is checked when no device is configured
                    let isActive = (self.selectedChromecastName == nil)
                    let prefix = isActive ? "✓ " : "  "
                    return "\(prefix)🚫 None (disable Chromecast)"
                }
            }
            // Default selection: active item if present, else first.
            let activeIndex = labels.firstIndex(where: { $0.hasPrefix("✓") }) ?? 0
            return (options, labels, activeIndex)
        }

        var (options, labels, activeIndex) = buildLabels()

        // Add timestamp label if we have cached results
        var timestampLabel: Label? = nil
        if case .completed(_, let timestamp) = discoveryState {
            let elapsed = Int(Date().timeIntervalSince(timestamp))
            let timeStr = elapsed < 60 ? "\(elapsed)s ago" : "\(elapsed/60)m ago"
            timestampLabel = Label("Last scanned: \(timeStr)")
            timestampLabel!.x = Pos.at(1)
            timestampLabel!.y = Pos.at(1)
            timestampLabel!.width = Dim.fill(1)
            dialog.addSubview(timestampLabel!)
        }

        let list = ListView(items: labels)
        list.allowMarking = false
        list.allowsMultipleSelection = false
        list.selectedItem = activeIndex
        list.selectedMarker = ">"
        list.x = Pos.at(1)
        list.y = timestampLabel != nil ? Pos.at(2) : Pos.at(1)
        list.width = Dim.fill(1)
        list.height = Dim.sized(listHeight)
        list.autoNavigateToNextViewOnBoundary = true
        dialog.addSubview(list)

        let ok = Button("OK")
        ok.isDefault = true
        ok.clicked = { [weak self] _ in
            guard let self else { return }
            let idx = list.selectedItem
            let deviceOpt = idx < options.count ? options[idx] : nil
            Application.requestStop()
            if let device = deviceOpt {
                completion(device)
                self.log("Chromecast dialog selection: \(device.name) model=\(device.model ?? "unknown") type=\(device.castType.rawValue)")
            } else {
                // None selected: disable Chromecast output and switch to mpv.
                self.disableChromecast(statusLabel: statusLabel)
                completion(nil)
                self.log("Chromecast dialog selection: None (disable Chromecast)")
            }
        }

        let cancel = Button("Cancel")
        cancel.clicked = { [weak self] _ in
            Application.requestStop()
            completion(nil)
            self?.log("Chromecast dialog cancelled")
        }

        let rescan = Button("Rescan")
        rescan.clicked = { [weak self] _ in
            guard let self else { return }

            // Check if already scanning
            if case .scanning = self.discoveryState {
                self.log("Rescan: already scanning, ignoring")
                statusLabel?.text = "Status: scan already in progress..."
                return
            }

            self.log("Rescan: triggering fresh discovery")
            statusLabel?.text = "Status: rescanning for Chromecasts..."

            // Show scanning message in the list
            list.items = ["  🔍 Scanning for Chromecasts..."]
            list.selectedItem = 0

            // Reset state to trigger fresh scan
            self.discoveryState = .idle

            // Start fresh discovery
            self.discoveryState = .scanning(started: Date())
            DispatchQueue.global(qos: .userInitiated).async {
                let discovered = (try? ChromecastDiscovery.discover(timeout: timeout)) ?? []
                let videos = discovered.filter { $0.isVideoCapable }

                DispatchQueue.main.async {
                    let scanTime = Date()
                    self.discoveryState = .completed(devices: videos, timestamp: scanTime)
                    self.log("Rescan: discovered \(videos.count) video-capable devices")

                    // Update timestamp label
                    timestampLabel?.text = "Last scanned: just now"

                    // Rebuild the full device list including "None" option
                    currentDevices = videos
                    let built = buildLabels()
                    options = built.0
                    list.items = built.1
                    list.selectedItem = built.2

                    if videos.isEmpty {
                        statusLabel?.text = "Status: no video-capable Chromecasts found (rescan)"
                        self.log("Rescan: 0 video-capable devices found")
                    } else {
                        statusLabel?.text = "Status: found \(videos.count) video-capable Chromecast(s)"
                        let names = videos.map { "\($0.name) (\($0.model ?? "unknown"))" }.joined(separator: ", ")
                        self.log("Rescan: \(videos.count) video-capable -> [\(names)]")
                    }
                }
            }
        }

        dialog.addButton(ok)
        dialog.addButton(cancel)
        dialog.addButton(rescan)

        Application.present(top: dialog)
    }

    private func disableChromecast(statusLabel: Label?) {
        // ONLY called when user explicitly selects "None" in discovery modal
        // This is the ONLY place (besides validation) where clearing selectedChromecastName is correct
        selectedOutput = .mpv
        outputRadio?.selected = OutputChoice.mpv.rawValue
        selectedChromecastName = nil  // Intentional: user chose "None"
        config.chromecast.defaultDevice = nil
        try? config.save()
        rebuildOutputRadio(chromecastName: nil, selected: OutputChoice.mpv.rawValue, statusLabel: statusLabel)
        persistDefaultOutput(.mpv)
        cleanupCurrentPlayer()
        statusLabel?.text = "Status: Chromecast disabled (mpv active)"
        if let radio = outputRadio {
            toplevel?.setFocus(radio)
        }
    }

    private func persistDefaultOutput(_ choice: OutputChoice) {
        config.ui.defaultOutput = (choice == .mpv) ? "mpv" : "chromecast"
        try? config.save()
    }

    private func cleanupCurrentPlayer() {
        playerHandle?.cleanup()
        playerHandle = nil
    }

    private func scrub(by offset: TimeInterval, statusLabel: Label?) {
        guard let player = playerHandle?.player else {
            statusLabel?.text = "Status: start playback first"
            return
        }
        let target = min(duration, max(0, lastKnownPosition + offset))
        do {
            try player.seek(to: target)
            lastKnownPosition = target
            statusLabel?.text = "Status: seek to \(formatTime(target))"
        } catch {
            statusLabel?.text = "Status: seek error \(error)"
        }
    }

    private func seekTo(_ target: TimeInterval, statusLabel: Label?) {
        guard let player = playerHandle?.player else {
            statusLabel?.text = "Status: start playback first"
            return
        }
        let clamped = min(max(0, target), duration)
        do {
            try player.seek(to: clamped)
            lastKnownPosition = clamped
            lastSeekTime = Date()
            statusLabel?.text = "Status: jump to \(formatTime(clamped))"
        } catch {
            statusLabel?.text = "Status: jump error \(error)"
        }
    }

    private func resetLog() {
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    private func log(_ message: String) {
        let line = "[TUI] \(message)"
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "--:--:--" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func parseTime(_ str: String) -> TimeInterval? {
        if let direct = Double(str) { return direct }
        let parts = str.split(separator: ":").map(String.init)
        if parts.count == 2,
           let m = Double(parts[0]),
           let s = Double(parts[1]) {
            return m * 60 + s
        }
        if parts.count == 3,
           let h = Double(parts[0]),
           let m = Double(parts[1]),
           let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        }
        return nil
    }

    private func focusAndJump(jumpField: TextField?, statusLabel: Label?) {
        guard let jumpField else { return }
        toplevel?.setFocus(jumpField)
        // If there's already text, attempt a jump.
        let text = jumpField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let target = parseTime(text) else { return }
        seekTo(target, statusLabel: statusLabel)
    }

    private func makeBarText(position: TimeInterval) -> String {
        let total = duration > 0 ? duration : 1
        // Compute bar width relative to the current toplevel width to avoid clipping.
        let totalColumns = max(20, Int(toplevel?.bounds.width ?? 80) - 2)  // subtract window border
        let clamped = max(0, min(position, total))
        let fraction = clamped / total
        let prefix = formatTime(clamped)
        let suffix = formatTime(duration)
        // 4 extra chars: " [", "] " around the bar plus one space before suffix.
        let fixed = prefix.count + suffix.count + 4
        let barWidth = max(5, min(100, totalColumns - fixed))
        let knobIndex = min(barWidth - 1, max(0, Int(Double(barWidth) * fraction)))
        let filledCount = max(0, knobIndex)
        let emptyCount = max(0, barWidth - knobIndex - 1)
        let filled = String(repeating: "=", count: filledCount)
        let empty = String(repeating: "-", count: emptyCount)
        let bar = "\(filled)|\(empty)"
        return "\(prefix) [\(bar)] \(suffix)"
    }

    private func rebuildOutputRadio(chromecastName: String?, selected: Int?, statusLabel: Label? = nil) {
        guard let frame = outputFrame else { return }
        if let radio = outputRadio {
            radio.superview?.removeSubview(radio)
        }

        // Only show Chromecast option if a device is configured
        var labels = ["_mpv"]
        if let name = chromecastName {
            labels.append("_Chromecast (\(name))")
        }

        let maxLen = labels.map { $0.count }.max() ?? 4
        let desiredWidth = max(40, maxLen + 6)
        frame.width = Dim.sized(min(desiredWidth, 70))

        // If Chromecast option doesn't exist, force selection to mpv
        let actualSelected = (chromecastName == nil && selected == OutputChoice.chromecast.rawValue) ? OutputChoice.mpv.rawValue : selected

        let newRadio = RadioGroup(labels: labels, selected: actualSelected, orientation: .vertical)
        newRadio.x = Pos.at(1)
        newRadio.y = Pos.at(1)
        frame.addSubview(newRadio)

        // Reattach handler
        newRadio.selectionChanged = { [weak self] _, _, newSelection in
            guard let self, let newSelection, let choice = OutputChoice(rawValue: newSelection) else { return }
            self.applyOutputChoice(choice, statusLabel: statusLabel)
        }
        outputRadio = newRadio
    }

    private func applyOutputChoice(_ choice: OutputChoice, statusLabel: Label?, forcePicker: Bool = false) {
        // Prevent concurrent output switches
        guard !isSwitchingOutput else {
            log("Output switch already in progress - ignoring request")
            statusLabel?.text = "Status: switching output..."
            return
        }

        isSwitchingOutput = true
        defer { isSwitchingOutput = false }

        statusLabel?.text = "Status: switching output..."

        switch choice {
        case .chromecast:
            if let button = chromecastButton {
                toplevel?.setFocus(button)
            }
            let previousChoice = selectedOutput
            log("Output selection changed to Chromecast; starting discovery dialog")
            // If we already have a device and not forcing a picker, just select it.
            if !forcePicker, let existing = selectedChromecastName {
                selectedOutput = .chromecast
                outputRadio?.selected = OutputChoice.chromecast.rawValue
                statusLabel?.text = "Status: Chromecast set to \(existing)"
                return
            }
            presentDiscovery(statusLabel: statusLabel, timeout: config.chromecast.discoveryTimeout) { [weak self, weak statusLabel] device in
                guard let self else { return }
                if let device {
                    self.selectedOutput = .chromecast
                    self.outputRadio?.selected = OutputChoice.chromecast.rawValue
                    self.cleanupCurrentPlayer()
                    self.config.chromecast.defaultDevice = device.name
                    try? self.config.save()
                    self.persistDefaultOutput(.chromecast)
                    statusLabel?.text = "Status: Chromecast set to \(device.name)"
                    self.selectedChromecastName = device.name
                    self.rebuildOutputRadio(chromecastName: device.name, selected: OutputChoice.chromecast.rawValue, statusLabel: statusLabel)
                    self.log("Chromecast selected: \(device.name) model=\(device.model ?? "unknown") type=\(device.castType.rawValue)")
                } else {
                    // User cancelled or no devices found - preserve configuration!
                    // Do not silently fall back; keep prior output selection.
                    if let prev = previousChoice {
                        self.outputRadio?.selected = prev.rawValue
                        self.selectedOutput = prev
                    }
                    statusLabel?.text = "Status: Chromecast selection cancelled or no devices found"
                    // IMPORTANT: Do NOT clear selectedChromecastName here!
                    // User cancelling discovery should preserve their previous config
                    // Radio label stays as-is (e.g., "Chromecast (Bedroom TV)")
                    self.log("Chromecast selection cancelled or no video-capable devices (config preserved)")
                }
            }
        case .mpv:
            log("Output selection changed to mpv (preserving Chromecast config: \(selectedChromecastName ?? "none"))")
            selectedOutput = .mpv
            outputRadio?.selected = OutputChoice.mpv.rawValue
            cleanupCurrentPlayer()
            persistDefaultOutput(.mpv)
            statusLabel?.text = "Status: mpv set"
            // IMPORTANT: Do NOT clear selectedChromecastName - preserve config!
            // Radio label should still show configured device even when playing via mpv
            rebuildOutputRadio(chromecastName: selectedChromecastName, selected: OutputChoice.mpv.rawValue, statusLabel: statusLabel)
        }
    }

    private func makeScheme(normalFore: Color, normalBack: Color, focusFore: Color, focusBack: Color) -> ColorScheme {
        let normal = Application.makeAttribute(fore: normalFore, back: normalBack)
        // Use a simple emphasis on focus without relying on driver-specific flags.
        let focus = Application.makeAttribute(fore: focusFore, back: focusBack)
        return ColorScheme(
            normal: normal,
            focus: focus,
            hotNormal: normal,
            hotFocus: focus
        )
    }
}
