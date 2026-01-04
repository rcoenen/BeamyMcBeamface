import XCTest
@testable import BeamyKit

final class PlayerTests: XCTestCase {
    func testMpvPlayerTracksSeekOffset() throws {
        let server = FakeServer()
        let controller = FakeMpvController()
        controller.position = 5
        controller.isPausedValue = true

        let player = MpvPlayer(controller: controller, server: server, streamURL: URL(string: "http://localhost/stream.ts")!)

        XCTAssertEqual(try player.getPosition(), 5)
        XCTAssertTrue(try player.isPaused())
        XCTAssertGreaterThan(player.extrapolatedPosition(now: Date().addingTimeInterval(0.5)), 5.4)

        controller.isPausedValue = true
        try player.seek(to: 30)
        controller.position = 2
        XCTAssertEqual(try player.getPosition(), 32)
        XCTAssertEqual(server.seekedTo, 30)
        XCTAssertEqual(controller.reloadedURL?.absoluteString, "http://localhost/stream.ts")
        XCTAssertTrue(server.isPaused) // pause restored after seek

        controller.isPausedValue = false
        try player.pause()
        XCTAssertTrue(server.isPaused)
        try player.resume()
        XCTAssertFalse(server.isPaused)
        XCTAssertFalse(try player.isPaused())
    }

    func testChromecastPlayerUsesStatusAndCommands() throws {
        var commands: [(String, Int?, [String: Any])] = []
        let status = MediaStatus(dictionary: [
            "mediaSessionId": 7,
            "currentTime": 12.5,
            "duration": 100.0,
            "playerState": "PAUSED"
        ])!

        let player = ChromecastPlayer(
            statusProvider: { status },
            commandSender: { type, id, additional in
                commands.append((type, id, additional))
            },
            reloadHandler: { _ in }
        )

        XCTAssertEqual(try player.getPosition(), 12.5)
        XCTAssertEqual(try player.getDuration(), 100.0)
        XCTAssertTrue(try player.isPaused())

        try player.pause()
        try player.resume()
        try player.seek(to: 55)

        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0].0, "PAUSE")
        XCTAssertEqual(commands[1].0, "PLAY")
        XCTAssertEqual(commands[2].0, "SEEK")
        XCTAssertEqual(commands[2].1, 7)
        XCTAssertEqual(commands[2].2["currentTime"] as? TimeInterval, 55)
    }

    func testChromecastPlayerThrowsWhenStatusMissing() {
        let player = ChromecastPlayer(
            statusProvider: { nil },
            commandSender: { _, _, _ in },
            reloadHandler: { _ in }
        )

        XCTAssertThrowsError(try player.getPosition()) { error in
            XCTAssertTrue(error is PlayerError)
        }
    }
}

// MARK: - Test Doubles

private final class FakeServer: ServerControlling {
    var currentPosition: TimeInterval = 0
    var isPaused: Bool = false
    var seekedTo: TimeInterval?

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func seek(to time: TimeInterval) {
        seekedTo = time
        currentPosition = time
    }

    func seek(to time: TimeInterval, awaitClientReconnect: Bool) {
        seek(to: time)
    }
}

private final class FakeMpvController: MpvControlling {
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPausedValue: Bool = false
    var reloadedURL: URL?

    func getPosition() throws -> TimeInterval { position }
    func getDuration() throws -> TimeInterval { duration }
    func isPaused() throws -> Bool { isPausedValue }
    func pause() throws { isPausedValue = true }
    func resume() throws { isPausedValue = false }
    func seek(to time: TimeInterval) throws { position = time }
    func reloadStream(_ url: URL) throws { reloadedURL = url; position = 0 }
}
