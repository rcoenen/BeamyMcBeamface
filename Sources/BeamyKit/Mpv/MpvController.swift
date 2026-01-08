import Foundation

/// Controller for mpv player via JSON IPC over Unix socket.
/// Acts as a Chromecast proxy - bidirectional communication for position, pause, play.
public final class MpvController: @unchecked Sendable {
    private let socketPath: String
    private var socketFD: Int32 = -1
    private var mpvProcess: Process?
    private var requestId: Int = 0

    public init(socketPath: String = "/tmp/beamy-mpv.socket") {
        self.socketPath = socketPath
    }

    // MARK: - Process Management

    /// Launch mpv with IPC socket, playing the given URL
    public func launch(url: URL, windowTitle: String = "Beamy Player") throws -> Process {
        // Remove old socket if exists
        try? FileManager.default.removeItem(atPath: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
        process.arguments = [
            "--input-ipc-server=\(socketPath)",
            "--force-window=immediate",
            "--title=\(windowTitle)",
            "--no-terminal",
            "--keep-open=yes",  // Don't quit at EOF (for live streams)
            "--cache=yes",
            "--cache-secs=10",
            url.absoluteString
        ]

        // Detach from terminal
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        mpvProcess = process

        // Wait for socket to be created
        var attempts = 0
        while !FileManager.default.fileExists(atPath: socketPath) && attempts < 50 {
            usleep(100_000)  // 100ms
            attempts += 1
        }

        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw MpvError.socketNotCreated
        }

        // Connect to socket
        try connect()

        return process
    }

    /// Connect to the IPC socket
    public func connect() throws {
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw MpvError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path to sun_path
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            pathBytes.withUnsafeBufferPointer { pathBuf in
                let destPtr = UnsafeMutableRawPointer(sunPathPtr)
                    .assumingMemoryBound(to: CChar.self)
                for i in 0..<min(pathBuf.count, 104) {  // sun_path is typically 104 bytes
                    destPtr[i] = pathBuf[i]
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult >= 0 else {
            close(socketFD)
            socketFD = -1
            throw MpvError.connectionFailed
        }
    }

    /// Disconnect from socket
    public func disconnect() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    /// Quit mpv
    public func quit() {
        _ = try? sendCommand(["quit"])
        disconnect()
        mpvProcess?.terminate()
        mpvProcess = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Playback Control

    /// Get current playback position in seconds
    public func getPosition() throws -> TimeInterval {
        let response = try sendCommand(["get_property", "playback-time"])
        guard let data = response["data"] as? Double else {
            // If playback hasn't started yet, return 0
            if let error = response["error"] as? String, error == "property unavailable" {
                return 0
            }
            throw MpvError.invalidResponse
        }
        return data
    }

    /// Get total duration
    public func getDuration() throws -> TimeInterval {
        let response = try sendCommand(["get_property", "duration"])
        guard let data = response["data"] as? Double else {
            return 0
        }
        return data
    }

    /// Check if paused
    public func isPaused() throws -> Bool {
        let response = try sendCommand(["get_property", "pause"])
        guard let data = response["data"] as? Bool else {
            throw MpvError.invalidResponse
        }
        return data
    }

    /// Pause playback
    public func pause() throws {
        _ = try sendCommand(["set_property", "pause", true])
    }

    /// Resume playback
    public func resume() throws {
        _ = try sendCommand(["set_property", "pause", false])
    }

    /// Toggle pause state
    public func togglePause() throws {
        let paused = try isPaused()
        if paused {
            try resume()
        } else {
            try pause()
        }
    }

    /// Seek to absolute position
    public func seek(to time: TimeInterval) throws {
        _ = try sendCommand(["seek", time, "absolute"])
    }

    /// Reload the current stream (clears buffer, starts fresh)
    public func reloadStream(_ url: URL) throws {
        _ = try sendCommand(["loadfile", url.absoluteString, "replace"])
    }

    // MARK: - IPC Communication

    /// Send a command and receive response
    @discardableResult
    public func sendCommand(_ command: [Any]) throws -> [String: Any] {
        guard socketFD >= 0 else {
            throw MpvError.notConnected
        }

        requestId += 1
        let message: [String: Any] = [
            "command": command,
            "request_id": requestId
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        var jsonString = String(data: jsonData, encoding: .utf8)! + "\n"

        // Send
        let sent = jsonString.withUTF8 { buffer in
            write(socketFD, buffer.baseAddress, buffer.count)
        }
        guard sent > 0 else {
            throw MpvError.sendFailed
        }

        // Receive (read until newline)
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(socketFD, &buffer, buffer.count)
            if bytesRead <= 0 {
                throw MpvError.receiveFailed
            }
            responseData.append(contentsOf: buffer[0..<bytesRead])

            // Check if we have a complete response (ends with newline)
            if buffer[bytesRead - 1] == 0x0A {  // newline
                break
            }
        }

        // Parse JSON response
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MpvError.invalidResponse
        }

        // Check for error
        if let error = response["error"] as? String, error != "success" {
            // Some errors are expected (e.g., property unavailable during startup)
            // Don't throw, just return the response
        }

        return response
    }

    deinit {
        quit()
    }
}

// MARK: - Errors

public enum MpvError: Error, CustomStringConvertible {
    case socketNotCreated
    case socketCreationFailed
    case connectionFailed
    case notConnected
    case sendFailed
    case receiveFailed
    case invalidResponse
    case commandFailed(String)

    public var description: String {
        switch self {
        case .socketNotCreated:
            return "mpv IPC socket was not created"
        case .socketCreationFailed:
            return "Failed to create Unix socket"
        case .connectionFailed:
            return "Failed to connect to mpv IPC socket"
        case .notConnected:
            return "Not connected to mpv"
        case .sendFailed:
            return "Failed to send command to mpv"
        case .receiveFailed:
            return "Failed to receive response from mpv"
        case .invalidResponse:
            return "Invalid response from mpv"
        case .commandFailed(let error):
            return "mpv command failed: \(error)"
        }
    }
}
