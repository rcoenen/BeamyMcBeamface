import ArgumentParser
import Foundation

@main
struct Beamy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beamy",
        abstract: "BeamyMcBeamface - Cast media files to Chromecast devices",
        version: "0.1.0",
        subcommands: [Cast.self, CastTest.self, Devices.self, ConfigCmd.self, ChromecastDiscover.self, FFmpegDiscover.self, TranscodeTest.self]
    )
}
