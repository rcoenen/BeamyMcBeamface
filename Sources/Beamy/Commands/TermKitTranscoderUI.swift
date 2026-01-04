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
    private let player: Player
    private let duration: TimeInterval
    private let onCleanup: (() -> Void)?
    private weak var toplevel: Toplevel?
    private var lastKnownPosition: TimeInterval = 0
    private var lastKnownPaused: Bool = false
    private var timer: DispatchSourceTimer?

    init(player: Player, duration: TimeInterval, onCleanup: (() -> Void)? = nil) {
        self.player = player
        self.duration = duration
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

        let statusLabel = Label("Status: connecting...")
        statusLabel.x = Pos.at(1)
        statusLabel.y = Pos.at(1)

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

        let playPauseButton = Button("Pause/Resume")
        playPauseButton.x = Pos.at(1)
        playPauseButton.y = Pos.bottom(of: barLabel) + 1
        playPauseButton.width = Dim.sized(16)
        playPauseButton.isDefault = true
        playPauseButton.clicked = { [weak self, weak statusLabel] _ in
            guard let self = self else { return }
            do {
                let paused = (try? self.player.isPaused()) ?? self.lastKnownPaused
                if paused {
                    try self.player.resume()
                    self.lastKnownPaused = false
                    statusLabel?.text = "Status: playing"
                } else {
                    try self.player.pause()
                    self.lastKnownPaused = true
                    statusLabel?.text = "Status: paused"
                }
            } catch {
                statusLabel?.text = "Status: error \(error)"
            }
        }

        let seekBackButton = Button("⟵ 10s")
        seekBackButton.x = Pos.right(of: playPauseButton) + 2
        seekBackButton.y = playPauseButton.y
        seekBackButton.width = Dim.sized(10)
        seekBackButton.clicked = { [weak self, weak statusLabel] _ in
            guard let self = self else { return }
            let target = max(0, self.lastKnownPosition - 10)
            do {
                try self.player.seek(to: target)
                statusLabel?.text = "Status: seek to \(self.formatTime(target))"
            } catch {
                statusLabel?.text = "Status: seek error \(error)"
            }
        }

        let seekForwardButton = Button("10s ⟶")
        seekForwardButton.x = Pos.right(of: seekBackButton) + 2
        seekForwardButton.y = playPauseButton.y
        seekForwardButton.width = Dim.sized(10)
        seekForwardButton.clicked = { [weak self, weak statusLabel] _ in
            guard let self = self else { return }
            let target = min(self.duration, self.lastKnownPosition + 10)
            do {
                try self.player.seek(to: target)
                statusLabel?.text = "Status: seek to \(self.formatTime(target))"
            } catch {
                statusLabel?.text = "Status: seek error \(error)"
            }
        }

        let quitButton = Button("Quit")
        quitButton.x = Pos.right(of: seekForwardButton) + 2
        quitButton.y = playPauseButton.y
        quitButton.width = Dim.sized(8)
        quitButton.clicked = { [weak self] _ in
            self?.onCleanup?()
            Application.requestStop()
        }

        let jumpLabel = Label("Jump to (s or hh:mm:ss):")
        jumpLabel.x = Pos.at(1)
        jumpLabel.y = Pos.bottom(of: playPauseButton) + 1

        let jumpField = TextField("")
        jumpField.x = Pos.right(of: jumpLabel) + 1
        jumpField.y = jumpLabel.y
        jumpField.width = Dim.fill() - Dim.sized(30)

        let jumpButton = Button("Jump")
        jumpButton.x = Pos.right(of: jumpField) + 1
        jumpButton.y = jumpLabel.y
        jumpButton.width = Dim.sized(8)
        jumpButton.clicked = { [weak self, weak statusLabel, weak jumpField] _ in
            guard let self = self else { return }
            let text = jumpField?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let target = self.parseTime(text) else {
                statusLabel?.text = "Status: invalid time '\(text)'"
                return
            }
            do {
                try self.player.seek(to: min(max(0, target), self.duration))
                self.lastKnownPosition = target
                statusLabel?.text = "Status: jump to \(self.formatTime(target))"
            } catch {
                statusLabel?.text = "Status: jump error \(error)"
            }
        }

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

        top.handleKey = { [weak self] event in
            guard let self = self else { return false }
            switch event.key {
            case .letter(let ch):
                switch ch {
                case "q", "Q":
                    self.onCleanup?()
                    Application.requestStop()
                    return true
                case "j", "J":
                    self.focusAndJump(jumpField: jumpField, statusLabel: statusLabel)
                    return true
                case " ":
                    self.togglePlayPause(statusLabel: statusLabel)
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
        onCleanup?()
    }

    private func startTimer(statusLabel: Label, timeLabel: Label, percentLabel: Label, barLabel: Label) {
        // Run on the main queue so TermKit views are only touched from one thread.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self, weak statusLabel, weak timeLabel, weak percentLabel] in
            guard let self = self else { return }
            let position: TimeInterval
            if let p = try? self.player.getPosition() {
                position = p
                self.lastKnownPosition = p
            } else if let mpv = self.player as? MpvPlayer {
                position = mpv.extrapolatedPosition()
                self.lastKnownPosition = position
            } else {
                position = self.lastKnownPosition
            }

            let paused = (try? self.player.isPaused()) ?? self.lastKnownPaused
            self.lastKnownPaused = paused

            let percent = self.duration > 0 ? (position / self.duration) * 100 : 0
            statusLabel?.text = "Status: \(paused ? "paused" : "playing")"
            timeLabel?.text = "Time: \(self.formatTime(position)) / \(self.formatTime(self.duration))"
            percentLabel?.text = "Progress: \(Int(round(percent)))%"
            barLabel.text = self.makeBarText(position: position)
        }
        self.timer = timer
        timer.resume()
    }

    private func togglePlayPause(statusLabel: Label?) {
        do {
            let paused = (try? player.isPaused()) ?? lastKnownPaused
            if paused {
                try player.resume()
                lastKnownPaused = false
                statusLabel?.text = "Status: playing"
            } else {
                try player.pause()
                lastKnownPaused = true
                statusLabel?.text = "Status: paused"
            }
        } catch {
            statusLabel?.text = "Status: error \(error)"
        }
    }

    private func scrub(by offset: TimeInterval, statusLabel: Label?) {
        let target = min(duration, max(0, lastKnownPosition + offset))
        do {
            try player.seek(to: target)
            statusLabel?.text = "Status: seek to \(formatTime(target))"
        } catch {
            statusLabel?.text = "Status: seek error \(error)"
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
        do {
            let clamped = min(max(0, target), duration)
            try player.seek(to: clamped)
            lastKnownPosition = clamped
            statusLabel?.text = "Status: jump to \(formatTime(clamped))"
        } catch {
            statusLabel?.text = "Status: jump error \(error)"
        }
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
}
