import SwiftUI
import AVKit
import AVFoundation

struct AVPlayerView: View {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    @State private var player: AVPlayer = AVPlayer()
    @State private var timeObserver: Any?
    @State private var isSeeking = false

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { setupPlayer() }
            .onDisappear { cleanup() }
            .onChange(of: url) { _ in setupPlayer() }
            .onChange(of: isPlaying) { newValue in syncPlaybackState(newValue) }
            .onChange(of: currentTime) { newValue in
                // Only seek if the change is significant (user drag vs time observer)
                if !isSeeking {
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
            player.replaceCurrentItem(with: nil)
            return
        }

        // Start accessing security-scoped resource (for sandboxed apps)
        let accessing = url.startAccessingSecurityScopedResource()

        // Create player item and replace current item
        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)

        // Set up time observer (fires every 0.25 seconds)
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
            DispatchQueue.main.async {
                self.currentTime = time.seconds

                // Update duration when available
                if let item = player?.currentItem {
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 {
                        self.duration = itemDuration
                    }
                }
            }
        }

        self.timeObserver = observer

        // Stop accessing security-scoped resource if we started it
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }

        // Auto-play if isPlaying is true
        if isPlaying {
            player.play()
        }
    }

    private func cleanup() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func syncPlaybackState(_ shouldPlay: Bool) {
        if shouldPlay {
            player.play()
        } else {
            player.pause()
        }
    }

    private func handleExternalSeek(to time: TimeInterval) {
        isSeeking = true
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: cmTime) { _ in
            Task { @MainActor in
                self.isSeeking = false
            }
        }
    }
}
