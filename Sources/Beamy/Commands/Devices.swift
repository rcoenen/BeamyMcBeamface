import ArgumentParser
import BeamyKit
import Foundation

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available Chromecast devices on the network"
    )

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Double = 5.0

    @Flag(name: .shortAndLong, help: "Show all devices including audio-only")
    var all: Bool = false

    func run() throws {
        print("Discovering Chromecast devices...")

        let allDevices = try ChromecastDiscovery.discover(timeout: timeout)
        let devices = all ? allDevices : allDevices.filter { $0.isVideoCapable }

        if devices.isEmpty {
            if allDevices.isEmpty {
                print("No Chromecast devices found")
            } else {
                print("No video-capable devices found. Use --all to show audio-only devices.")
            }
        } else {
            let label = all ? "device(s)" : "video-capable device(s)"
            print("\nFound \(devices.count) \(label):\n")
            for device in devices {
                let typeIcon = device.isVideoCapable ? "📺" : (device.castType == .group ? "🔊" : "🔈")
                print("  \(typeIcon) \(device.name)")
                print("    Model: \(device.model ?? "Unknown")")
                print("    Type: \(device.capabilityDescription)")
                print("    IP: \(device.address):\(device.port)")
                print()
            }
        }
    }
}
