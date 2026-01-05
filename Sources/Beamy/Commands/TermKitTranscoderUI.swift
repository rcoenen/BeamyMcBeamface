import Foundation
import BeamyKit
import TermKit

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
        outputFrame.x = Pos.at(1)
        outputFrame.y = Pos.at(1)
        // Size to fit the longest label plus padding/border.
        outputFrame.width = Dim.sized(20)
        outputFrame.height = Dim.sized(5)

        let outputRadio = RadioGroup(labels: ["_mpv", "_Chromecast"], selected: selectedOutput?.rawValue, orientation: .vertical)
        outputRadio.x = Pos.at(1)
        outputRadio.y = Pos.at(1)
        outputRadio.selectionChanged = { [weak self] _, _, newSelection in
            guard let self else { return }
            if let choice = newSelection.flatMap(OutputChoice.init(rawValue:)) {
                self.selectedOutput = choice
                // Stop current player when switching outputs; new player starts on next Play.
                self.cleanupCurrentPlayer()
                self.persistDefaultOutput(choice)
            }
        }
        outputFrame.addSubview(outputRadio)

        let statusLabel = Label("Status: idle (choose output, press Play)")
        statusLabel.x = Pos.at(1)
        statusLabel.y = Pos.bottom(of: outputFrame) + 1

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
        playPauseButton.isDefault = true
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
        let shortcutsLabel = Label("Keys: Space=Play/Pause  [=Seek -10s  ]=Seek +10s  J=Jump  Q=Quit")
        shortcutsLabel.x = Pos.at(1)
        shortcutsLabel.y = Pos.bottom(of: jumpField) + 1
        window.addSubview(shortcutsLabel)

        top.addSubview(window)
        Application.top.addSubview(top)

        top.handleKey = { [weak self, weak outputRadio, weak jumpField, weak statusLabel] event in
            guard let self = self else { return false }
            // Let the radio group handle its own keys when focused (space/enter), but still allow global shortcuts.
            if outputRadio?.hasFocus == true {
                if case .letter(let ch) = event.key {
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
                        break
                    }
                }
                return false
            }
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
                case " ":
                    self.handlePlayPause(statusLabel: statusLabel)
                    return true
                case "[":
                    self.scrub(by: -10, statusLabel: statusLabel)
                    return true
                case "]":
                    self.scrub(by: 10, statusLabel: statusLabel)
                    return true
                default:
                    return false
                }
            default:
                return false
            }
        }

        startTimer(statusLabel: statusLabel, timeLabel: timeLabel, percentLabel: percentLabel, barLabel: barLabel)
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

    private func ensurePlayerAvailable(statusLabel: Label?, completion: @escaping (Bool) -> Void) {
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
            resolveChromecastDevice(statusLabel: statusLabel) { device in
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
        let controller = MpvController()
        _ = try controller.launch(url: server.url, windowTitle: "Beamy Player (mpv)")
        let player = MpvPlayer(controller: controller, server: server, streamURL: server.url)
        if lastKnownPosition > 0 {
            try? player.seek(to: lastKnownPosition)
        }
        if lastKnownPaused {
            try? player.pause()
        }
        return PlayerHandle(output: .mpv, player: player, cleanup: {
            controller.quit()
        })
    }

    private func launchChromecast(to device: ChromecastDevice) throws -> PlayerHandle {
        let client = CastV2Client(device: device, verbose: true)
        try client.connect()
        try client.launchDefaultMediaReceiver()
        try client.loadMedia(url: server.url, contentType: "video/mp2t", title: title, isLive: true)
        let player = ChromecastPlayer(client: client)
        if lastKnownPosition > 0 {
            try? player.seek(to: lastKnownPosition)
        }
        if lastKnownPaused {
            try? player.pause()
        }
        return PlayerHandle(output: .chromecast, player: player, cleanup: {
            client.disconnect()
        })
    }

    private func resolveChromecastDevice(statusLabel: Label?, completion: @escaping (ChromecastDevice?) -> Void) {
        let timeout = config.chromecast.discoveryTimeout
        if let preferred = config.chromecast.defaultDevice {
            statusLabel?.text = "Status: checking Chromecast \(preferred)..."
            let device = try? ChromecastDiscovery.findDevice(named: preferred, timeout: timeout)
            if let device {
                completion(device)
            } else {
                presentDiscovery(statusLabel: statusLabel, timeout: timeout, completion: completion)
            }
        } else {
            presentDiscovery(statusLabel: statusLabel, timeout: timeout, completion: completion)
        }
    }

    private func presentDiscovery(statusLabel: Label?, timeout: Double, completion: @escaping (ChromecastDevice?) -> Void) {
        statusLabel?.text = "Status: discovering Chromecast devices..."
        let devices = (try? ChromecastDiscovery.discover(timeout: timeout)) ?? []
        if devices.isEmpty {
            statusLabel?.text = "Status: no Chromecast devices found"
            completion(nil)
            return
        }
        showDiscoveryDialog(devices: devices, completion: completion)
    }

    private func showDiscoveryDialog(devices: [ChromecastDevice], completion: @escaping (ChromecastDevice?) -> Void) {
        let width = min(max(50, devices.map { $0.name.count }.max() ?? 0 + 10), 80)
        let height = min(max(8, devices.count + 4), 20)
        let dialog = Dialog(title: "Select Chromecast", width: width, height: height, buttons: [])
        dialog.modal = true
        dialog.closedCallback = {
            completion(nil)
        }

        let list = ListView(items: devices.map { $0.name })
        list.allowMarking = false
        list.allowsMultipleSelection = false
        list.selectedItem = 0
        list.x = Pos.at(1)
        list.y = Pos.at(1)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)
        dialog.addSubview(list)

        let ok = Button("OK")
        ok.clicked = { _ in
            let idx = list.selectedItem
            let device = idx < devices.count ? devices[idx] : devices.first
            Application.requestStop()
            completion(device)
        }

        let cancel = Button("Cancel")
        cancel.clicked = { _ in
            Application.requestStop()
            completion(nil)
        }

        dialog.addButton(ok)
        dialog.addButton(cancel)

        Application.present(top: dialog)
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
            statusLabel?.text = "Status: jump to \(formatTime(clamped))"
        } catch {
            statusLabel?.text = "Status: jump error \(error)"
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
