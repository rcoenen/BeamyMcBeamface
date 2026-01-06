import SwiftUI
import AVKit

/// NSViewRepresentable wrapper around AVPlayerView that plays any URL (files or streams).
/// Exposes a coordinator so the view model can control playback.
struct AVPlayerView: NSViewRepresentable {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    var onCoordinatorReady: ((Coordinator) -> Void)?

    func makeNSView(context: Context) -> AVKit.AVPlayerView {
        let view = AVKit.AVPlayerView()
        view.controlsStyle = .none
        view.player = context.coordinator.player
        onCoordinatorReady?(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: AVKit.AVPlayerView, context: Context) {
        // Load URL if changed
        if context.coordinator.currentURL != url, let url = url {
            context.coordinator.load(url: url, autoPlay: isPlaying)
        }

        // Sync play/pause
        if isPlaying {
            context.coordinator.play()
        } else {
            context.coordinator.pause()
        }

        // Seek if binding moved significantly
        context.coordinator.syncSeek(target: currentTime)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPlaying: $isPlaying,
            currentTime: $currentTime,
            duration: $duration
        )
    }

    final class Coordinator: NSObject {
        let player = AVPlayer()
        fileprivate var currentURL: URL?
        private var timeObserver: Any?
        private var durationObservation: NSKeyValueObservation?

        private var isPlayingBinding: Binding<Bool>
        private var currentTimeBinding: Binding<TimeInterval>
        private var durationBinding: Binding<TimeInterval>

        private var lastSeekTarget: TimeInterval = 0

        init(isPlaying: Binding<Bool>, currentTime: Binding<TimeInterval>, duration: Binding<TimeInterval>) {
            self.isPlayingBinding = isPlaying
            self.currentTimeBinding = currentTime
            self.durationBinding = duration
            super.init()
            attachObservers()
        }

        func load(url: URL, autoPlay: Bool) {
            currentURL = url
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            attachDurationObservation(to: item)
            if autoPlay {
                play()
            } else {
                pause()
            }
            lastSeekTarget = 0
        }

        func play() {
            player.play()
            isPlayingBinding.wrappedValue = true
        }

        func pause() {
            player.pause()
            isPlayingBinding.wrappedValue = false
        }

        func togglePause() {
            if player.timeControlStatus == .paused {
                play()
            } else {
                pause()
            }
        }

        func seek(to time: TimeInterval) {
            lastSeekTarget = time
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        func syncSeek(target: TimeInterval) {
            // avoid redundant seeks if we're already near the target
            if abs(lastSeekTarget - target) < 0.1 { return }
            seek(to: target)
        }

        private func attachObservers() {
            // Time observer
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                let seconds = time.seconds
                currentTimeBinding.wrappedValue = seconds
                let playing = player.timeControlStatus == .playing
                isPlayingBinding.wrappedValue = playing
            }

            if let item = player.currentItem {
                attachDurationObservation(to: item)
            }
        }

        private func attachDurationObservation(to item: AVPlayerItem) {
            durationObservation = item.observe(\.duration, options: [.new]) { [weak self] _, change in
                guard let self, let newDuration = change.newValue else { return }
                let seconds = newDuration.seconds
                if seconds.isFinite && seconds > 0 {
                    durationBinding.wrappedValue = seconds
                }
            }
        }

        deinit {
            if let obs = timeObserver {
                player.removeTimeObserver(obs)
            }
            durationObservation = nil
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
