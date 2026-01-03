import ArgumentParser
import Foundation

struct ChromecastDiscover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chromecast-discover",
        abstract: "Discover Chromecast devices and set default device"
    )

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Double = 5.0

    func run() throws {
        print("Discovering Chromecast devices...")

        let allDevices = try ChromecastDiscovery.discover(timeout: timeout)
        let devices = allDevices.filter { $0.isVideoCapable }

        guard !devices.isEmpty else {
            if allDevices.isEmpty {
                printNoDevicesFoundHelp()
            } else {
                print("No video-capable Chromecast devices found.")
                print("Found \(allDevices.count) audio-only device(s), but Beamster requires a display.")
            }
            return
        }

        print("\nFound \(devices.count) video-capable device(s):\n")
        for (index, device) in devices.enumerated() {
            print("  \(index + 1). \(device.name)")
            print("     Model: \(device.model ?? "Unknown")")
            print("     IP: \(device.address):\(device.port)")
            print()
        }

        // User selection loop
        let selectedDevice = try selectDevice(from: devices)

        // Update configuration
        do {
            var config = try Config.load()
            config.chromecast.defaultDevice = selectedDevice.name
            try config.save()

            print("\nSelected: \(selectedDevice.name)")
            print("Configuration updated successfully!")
            print()
            print("Default device set to: \(selectedDevice.name)")
            print("Config location: \(Config.configPath.path)")
        } catch {
            print("\nError: Unable to save configuration: \(error.localizedDescription)")
            print("\nPlease check file permissions for: \(Config.configPath.path)")
            throw ExitCode.failure
        }
    }

    private func selectDevice(from devices: [ChromecastDevice]) throws -> ChromecastDevice {
        while true {
            print("Select a device (1-\(devices.count)) or press Enter to cancel: ", terminator: "")
            fflush(stdout)

            guard let input = readLine() else {
                // EOF (Ctrl+D)
                print("\nCancelled. Configuration not modified.")
                throw ExitCode.failure
            }

            // Handle cancellation (empty input)
            let trimmedInput = input.trimmingCharacters(in: .whitespaces)
            if trimmedInput.isEmpty {
                print("Cancelled. Configuration not modified.")
                throw ExitCode.failure
            }

            // Validate and parse
            guard let selection = Int(trimmedInput),
                  selection >= 1 && selection <= devices.count else {
                print("Invalid selection. Please enter a number between 1 and \(devices.count).")
                continue
            }

            // Valid selection
            return devices[selection - 1]
        }
    }

    private func printNoDevicesFoundHelp() {
        print("No Chromecast devices found on the network.")
        print()
        print("Please ensure:")
        print("  - Your Chromecast devices are powered on")
        print("  - You're on the same network as your Chromecast devices")
        print("  - Your firewall allows mDNS traffic")
    }
}
