import ArgumentParser
import BeamyKit
import Foundation

struct ConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage Beamy configuration",
        subcommands: [Show.self, Init.self, Path.self]
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show current configuration"
        )

        func run() throws {
            let config = try Config.load()
            print(config.toTOMLString())
        }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Initialize configuration file with defaults"
        )

        @Flag(name: .shortAndLong, help: "Overwrite existing configuration")
        var force: Bool = false

        func run() throws {
            let path = Config.configPath

            if !force && FileManager.default.fileExists(atPath: path.path) {
                print("Configuration already exists at: \(path.path)")
                print("Use --force to overwrite")
                return
            }

            let config = Config.default
            try config.save()

            print("Configuration initialized at: \(path.path)")
            print("\nCurrent settings:")
            print(config.toTOMLString())
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show path to configuration file"
        )

        func run() {
            print(Config.configPath.path)
        }
    }
}
