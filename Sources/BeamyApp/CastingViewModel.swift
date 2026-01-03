import SwiftUI
import BeamyKit

@MainActor
class CastingViewModel: ObservableObject {
    @Published var devices: [ChromecastDevice] = []
    @Published var selectedDevice: ChromecastDevice?
    @Published var currentFile: URL?
    @Published var isCasting = false
    @Published var isDiscovering = false
    @Published var errorMessage: String?

    private var caster: Caster?

    init() {
        // Load default device from config
        loadDefaultDevice()
        // Start device discovery
        discoverDevices()
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

                    // Select default device if configured
                    if let defaultName = try? Config.load().chromecast.defaultDevice {
                        self.selectedDevice = videoDevices.first { $0.name == defaultName }
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
        // Check if it's a video file
        let videoExtensions = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "flv", "wmv"]
        guard videoExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "Unsupported file type. Please drop a video file."
            return
        }

        currentFile = url

        // Auto-cast if device is selected
        if selectedDevice != nil {
            startCasting()
        }
    }

    func startCasting() {
        guard let file = currentFile, let device = selectedDevice else {
            errorMessage = "Please select a device and drop a video file."
            return
        }

        guard !isCasting else { return }

        isCasting = true
        errorMessage = nil

        Task {
            do {
                // Get media info
                let mediaInfo = try FFmpeg.getMediaInfo(file: file)

                // Create caster and start casting
                let caster = Caster(device: device, verbose: false)
                self.caster = caster

                // Note: cast() is blocking, so we run it in a detached task
                Task.detached {
                    do {
                        try caster.cast(file: file, mediaInfo: mediaInfo)
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Casting failed: \(error.localizedDescription)"
                            self.isCasting = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to analyze file: \(error.localizedDescription)"
                    self.isCasting = false
                }
            }
        }
    }

    func stopCasting() {
        caster = nil
        isCasting = false
    }

    private func loadDefaultDevice() {
        if let config = try? Config.load(),
           let defaultName = config.chromecast.defaultDevice {
            // Device will be selected after discovery completes
            _ = defaultName
        }
    }
}
