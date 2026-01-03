import ArgumentParser
import BeamyKit
import Foundation

struct Cast: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cast a media file to a Chromecast device"
    )

    @Argument(help: "Path to the media file (MKV)")
    var file: String

    @Option(name: .shortAndLong, help: "Target device name or IP")
    var device: String?

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() throws {
        let fileURL = URL(fileURLWithPath: file)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        print("Preparing to cast: \(fileURL.lastPathComponent)")

        // Check if FFmpeg is available
        guard FFmpeg.isAvailable() else {
            throw ValidationError("FFmpeg not found. Please install FFmpeg (brew install ffmpeg)")
        }

        // Get media info
        if verbose {
            print("Analyzing media file...")
        }

        let mediaInfo = try FFmpeg.getMediaInfo(file: fileURL)
        print("Duration: \(mediaInfo.durationFormatted)")
        print("Video: \(mediaInfo.videoCodec ?? "unknown")")
        print("Audio: \(mediaInfo.audioCodec ?? "unknown")")

        // Discover or connect to device
        let targetDevice: ChromecastDevice
        if let deviceName = device {
            print("Looking for device: \(deviceName)...")
            guard let found = try ChromecastDiscovery.findDevice(named: deviceName) else {
                throw ValidationError("Device not found: \(deviceName)")
            }
            targetDevice = found
        } else {
            // Check config for default device
            if let config = try? Config.load(),
               let defaultDevice = config.chromecast.defaultDevice {
                print("Using default device: \(defaultDevice)...")
                if let found = try ChromecastDiscovery.findDevice(named: defaultDevice, timeout: 5.0) {
                    targetDevice = found
                } else {
                    print("Default device not found, discovering...")
                    let devices = try ChromecastDiscovery.discover(timeout: 5.0).filter { $0.isVideoCapable }
                    guard let first = devices.first else {
                        throw ValidationError("No video-capable Chromecast devices found")
                    }
                    targetDevice = first
                }
            } else {
                print("Discovering Chromecast devices...")
                let devices = try ChromecastDiscovery.discover(timeout: 5.0).filter { $0.isVideoCapable }
                guard let first = devices.first else {
                    throw ValidationError("No video-capable Chromecast devices found")
                }
                targetDevice = first
                print("Found: \(targetDevice.name)")
            }
        }

        // Start transcoding and casting
        print("Starting cast to \(targetDevice.name)...")

        let caster = Caster(device: targetDevice, verbose: verbose)
        try caster.cast(file: fileURL, mediaInfo: mediaInfo)
    }
}
