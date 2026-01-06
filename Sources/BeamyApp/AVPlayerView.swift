import SwiftUI
import AVKit
import AVFoundation

struct AVPlayerView: NSViewRepresentable {
    typealias NSViewType = AVKit.AVPlayerView

    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    func makeNSView(context: Context) -> NSViewType {
        let view = NSViewType()
        view.controlsStyle = .none  // We have our own controls
        view.player = context.coordinator.player

        context.coordinator.setupPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: NSViewType, context: Context) {
        // Update player when URL changes
        if context.coordinator.currentURL != url {
            context.coordinator.setupPlayer(url: url)
        }

        // Sync playback state
        context.coordinator.syncPlaybackState(isPlaying)

        // Handle seek requests
        context.coordinator.handleSeek(to: currentTime)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPlaying: $isPlaying,
            currentTime: $currentTime,
            duration: $duration
        )
    }

    class Coordinator: NSObject {
        let player = AVPlayer()
        var timeObserver: Any?
        var currentURL: URL?
        var isSeeking = false
        var lastSeekTime: TimeInterval = 0

        @Binding var isPlaying: Bool
        @Binding var currentTime: TimeInterval
        @Binding var duration: TimeInterval

        init(isPlaying: Binding<Bool>, currentTime: Binding<TimeInterval>, duration: Binding<TimeInterval>) {
            _isPlaying = isPlaying
            _currentTime = currentTime
            _duration = duration
            super.init()
        }

        func setupPlayer(url: URL?) {
            // Clean up old observer
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }

            guard let url = url else {
                player.replaceCurrentItem(with: nil)
                currentURL = nil
                return
            }

            currentURL = url

            // Start accessing security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()

            // Create and load player item
            let playerItem = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: playerItem)

            // Set up time observer (fires every 0.25 seconds)
            let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self, !self.isSeeking else { return }

                self.currentTime = time.seconds

                // Update duration when available
                if let item = self.player.currentItem {
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 {
                        self.duration = itemDuration
                    }
                }
            }

            timeObserver = observer

            // Stop accessing security-scoped resource
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }

            // Auto-play if needed
            if isPlaying {
                player.play()
            }
        }

        func syncPlaybackState(_ shouldPlay: Bool) {
            if shouldPlay && player.rate == 0 {
                player.play()
            } else if !shouldPlay && player.rate > 0 {
                player.pause()
            }
        }

        func handleSeek(to time: TimeInterval) {
            // Only seek if the change is significant (user drag vs time observer)
            guard !isSeeking else { return }

            let playerTime = CMTimeGetSeconds(player.currentTime())
            if abs(time - playerTime) > 1.0 {
                isSeeking = true
                lastSeekTime = time

                let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: cmTime) { [weak self] _ in
                    self?.isSeeking = false
                }
            }
        }

        deinit {
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
            }
            player.replaceCurrentItem(with: nil)
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
}
