import ArgumentParser
import Foundation

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available Chromecast devices on the network"
    )

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Double = 5.0

    func run() throws {
        print("Discovering Chromecast devices...")

        let devices = try ChromecastDiscovery.discover(timeout: timeout)

        if devices.isEmpty {
            print("No Chromecast devices found")
        } else {
            print("\nFound \(devices.count) device(s):\n")
            for device in devices {
                print("  \(device.name)")
                print("    IP: \(device.address):\(device.port)")
                print("    Model: \(device.model ?? "Unknown")")
                print()
            }
        }
    }
}
