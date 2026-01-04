import Foundation
import TermKit
import BeamyKit

/// A TermKit-based UI for controlling playback via the Player abstraction.
/// Keeps the existing CLI flags; opt-in via `--termkit` in TranscodeTest.
final class TermKitTranscoderUI {
    private let player: Player
    private let duration: TimeInterval
    private var lastKnownPosition: TimeInterval = 0
    private var lastKnownPaused: Bool = false
    private var timer: DispatchSourceTimer?

    init(player: Player, duration: TimeInterval) {
        self.player = player
        self.duration = duration
    }

    func run() throws {
        Application.prepare()

        let top = Toplevel()
        top.fill()

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

        let percentLabel = Label("Progress: 0.0%")
        percentLabel.x = Pos.at(1)
        percentLabel.y = Pos.bottom(of: timeLabel) + 1

        let playPauseButton = Button("Pause/Resume")
        playPauseButton.x = Pos.at(1)
        playPauseButton.y = Pos.bottom(of: percentLabel) + 1
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
        quitButton.clicked = { _ in
            Application.requestStop()
        }

        window.addSubview(statusLabel)
        window.addSubview(timeLabel)
        window.addSubview(percentLabel)
        window.addSubview(playPauseButton)
        window.addSubview(seekBackButton)
        window.addSubview(seekForwardButton)
        window.addSubview(quitButton)

        top.addSubview(window)

        startTimer(statusLabel: statusLabel, timeLabel: timeLabel, percentLabel: percentLabel)
        Application.run()
        timer?.cancel()
    }

    private func startTimer(statusLabel: Label, timeLabel: Label, percentLabel: Label) {
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
            percentLabel?.text = String(format: "Progress: %.1f%%", percent)
        }
        self.timer = timer
        timer.resume()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "--:--:--" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
