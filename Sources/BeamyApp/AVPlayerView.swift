import SwiftUI
import AVKit
import AVFoundation

struct AVPlayerView: View {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var isSeeking = false

    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear { setupPlayer() }
                    .onDisappear { cleanup() }
            } else {
                Color.black
                    .overlay(
                        Text("No video loaded")
                            .foregroundColor(.white)
                    )
                    .onAppear { setupPlayer() }
            }
        }
        .onChange(of: url) { _ in setupPlayer() }
        .onChange(of: isPlaying) { newValue in syncPlaybackState(newValue) }
        .onChange(of: currentTime) { newValue in
            // Only seek if the change is significant (user drag vs time observer)
            if let player = player, !isSeeking {
                let playerTime = CMTimeGetSeconds(player.currentTime())
                if abs(newValue - playerTime) > 1.0 {
                    handleExternalSeek(to: newValue)
                }
            }
        }
    }

    // MARK: - Format Detection

    /// Check if AVPlayer can play the given URL
    static func canPlay(url: URL) -> Bool {
        // Filter by extension - AVPlayer typically supports:
        // MP4, MOV, M4V, M4A (MPEG-4 containers)
        // Does NOT support: MKV, WebM, AVI
        let supportedExtensions = ["mp4", "mov", "m4v", "m4a", "3gp"]
        let ext = url.pathExtension.lowercased()

        return supportedExtensions.contains(ext)
    }

    // MARK: - Player Lifecycle

    private func setupPlayer() {
        cleanup()

        guard let url = url else {
            player = nil
            return
        }

        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)

        // Set up time observer (fires every 0.25 seconds)
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let observer = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                self.currentTime = time.seconds

                // Update duration when available
                if let item = newPlayer.currentItem {
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 {
                        self.duration = itemDuration
                    }
                }
            }
        }

        self.timeObserver = observer
        self.player = newPlayer

        // Auto-play if isPlaying is true
        if isPlaying {
            newPlayer.play()
        }
    }

    private func cleanup() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        player?.pause()
        player = nil
    }

    private func syncPlaybackState(_ shouldPlay: Bool) {
        guard let player = player else { return }

        if shouldPlay {
            player.play()
        } else {
            player.pause()
        }
    }

    private func handleExternalSeek(to time: TimeInterval) {
        guard let player = player else { return }

        isSeeking = true
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: cmTime) { _ in
            Task { @MainActor in
                self.isSeeking = false
            }
        }
    }
}
