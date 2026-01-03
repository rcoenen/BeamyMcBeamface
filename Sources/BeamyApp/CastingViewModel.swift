import SwiftUI
import BeamyKit
import AVKit
import WebKit
import Combine

@MainActor
class CastingViewModel: ObservableObject {
    @Published var devices: [ChromecastDevice] = []
    @Published var selectedDevice: ChromecastDevice? {
        didSet {
            saveSelectedDevice()
        }
    }
    @Published var currentFile: URL?
    @Published var mediaInfo: MediaInfo?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isCasting = false
    @Published var isDiscovering = false
    @Published var errorMessage: String?

    private var caster: Caster?
    var transcodeServer: TranscodeServer?
    private var isLoadingConfig = false

    // Computed properties for UI
    var progress: Double {
        duration > 0 ? currentTime / duration : 0
    }

    var timeRemaining: TimeInterval {
        max(0, duration - currentTime)
    }

    init() {
        isLoadingConfig = true
        discoverDevices()
        isLoadingConfig = false
    }

    private func saveSelectedDevice() {
        guard !isLoadingConfig else { return }
        guard var config = try? Config.load() else { return }
        config.chromecast.defaultDevice = selectedDevice?.name
        try? config.save()
    }

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

    func handleFileDrop(url: URL) {
        print("[DROP] File dropped: \(url.path)")

        let videoExtensions = ["mp4", "mkv", "webm", "mov", "avi", "m4v"]
        guard videoExtensions.contains(url.pathExtension.lowercased()) else {
            print("[DROP] Rejected - unsupported extension: \(url.pathExtension)")
            errorMessage = "Unsupported file type. Please drop a video file."
            return
        }

        print("[DROP] Extension OK, stopping preview...")
        stopPreview()
        currentFile = url
        errorMessage = nil

        // Get media info for duration
        print("[DROP] Getting media info...")
        do {
            let info = try FFmpeg.getMediaInfo(file: url)
            self.mediaInfo = info
            self.duration = info.duration
            print("[DROP] Media info OK - duration: \(info.duration)")
        } catch {
            print("[DROP] Media info FAILED: \(error)")
            errorMessage = "Failed to read media info: \(error.localizedDescription)"
            return
        }

        print("[DROP] Starting transcoder...")
        startTranscoder()
    }

    private func startTranscoder() {
        guard let url = currentFile, let info = mediaInfo else {
            print("[TRANSCODER] No file or media info!")
            return
        }

        let port = findAvailablePort()
        print("[TRANSCODER] Using port \(port)")

        do {
            let server = try TranscodeServer(input: url, port: port, mediaInfo: info)
            self.transcodeServer = server
            print("[TRANSCODER] Server started at \(server.url)")

            // Track transcoder progress
            server.onProgress = { [weak self] time in
                DispatchQueue.main.async {
                    self?.currentTime = time
                }
            }

            isPlaying = true
            print("[TRANSCODER] Ready! Playing at \(server.url)")
        } catch {
            print("[TRANSCODER] FAILED: \(error)")
            errorMessage = "Failed to start transcoder: \(error.localizedDescription)"
        }
    }

    private func findAvailablePort() -> Int {
        // Try to find an available port starting from 8080
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

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        transcodeServer?.resume()
        isPlaying = true
    }

    func pause() {
        transcodeServer?.pause()
        isPlaying = false
    }

    func skipForward() {
        seek(to: currentTime + 10)
    }

    func skipBackward() {
        seek(to: max(0, currentTime - 10))
    }

    func seek(to time: TimeInterval) {
        transcodeServer?.seek(to: time)
        currentTime = time
    }

    func seekToProgress(_ progress: Double) {
        let time = progress * duration
        seek(to: time)
    }

    func stopPreview() {
        transcodeServer?.stop()
        transcodeServer = nil
        isPlaying = false
        currentTime = 0
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00:00" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
