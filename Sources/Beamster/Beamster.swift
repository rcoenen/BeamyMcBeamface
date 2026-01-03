import ArgumentParser
import Foundation

@main
struct Beamster: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beamster",
        abstract: "Cast media files to Chromecast devices",
        version: "0.1.0",
        subcommands: [Cast.self, Devices.self, ConfigCmd.self, ChromecastDiscover.self]
    )
}
