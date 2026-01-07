import SwiftUI
import AppKit

/// SwiftUI wrapper for embedded mpv player using --wid for window embedding
struct MpvPlayerView: NSViewRepresentable {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    var onCoordinatorReady: ((Coordinator) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = MpvContainerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.containerView = view
        onCoordinatorReady?(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Load URL if changed
        if context.coordinator.currentURL != url, let url = url {
            context.coordinator.load(url: url)
        }

        // Update container view reference for resize handling
        if let containerView = nsView as? MpvContainerView {
            context.coordinator.containerView = containerView
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPlaying: $isPlaying,
            currentTime: $currentTime,
            duration: $duration
        )
    }

    @MainActor
    class Coordinator: NSObject {
        var containerView: MpvContainerView?
        var currentURL: URL?
        nonisolated(unsafe) private var mpvController: JsonIpcMpvController?
        private var positionTimer: Timer?

        nonisolated(unsafe) private var isPlayingBinding: Binding<Bool>
        nonisolated(unsafe) private var currentTimeBinding: Binding<TimeInterval>
        nonisolated(unsafe) private var durationBinding: Binding<TimeInterval>

        init(isPlaying: Binding<Bool>, currentTime: Binding<TimeInterval>, duration: Binding<TimeInterval>) {
            self.isPlayingBinding = isPlaying
            self.currentTimeBinding = currentTime
            self.durationBinding = duration
            super.init()
        }

        func load(url: URL) {
            currentURL = url
            print("DEBUG: MpvPlayerView loading: \(url)")

            // Stop any existing mpv
            stop()

            guard let containerView = containerView else {
                print("DEBUG: No container view")
                return
            }

            // We need to wait for the view to be in a window
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                self?.launchMpv(url: url, in: containerView)
            }
        }

        private func launchMpv(url: URL, in containerView: MpvContainerView) {
            // Get the window ID (NSView pointer as integer for --wid on macOS)
            let viewPointer = Unmanaged.passUnretained(containerView).toOpaque()
            let wid = Int(bitPattern: viewPointer)

            print("DEBUG: Launching mpv with wid: \(wid)")

            let socketPath = "/tmp/beamy-embedded-mpv-\(ProcessInfo.processInfo.processIdentifier).socket"

            // Remove old socket
            try? FileManager.default.removeItem(atPath: socketPath)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
            process.arguments = [
                "--wid=\(wid)",
                "--input-ipc-server=\(socketPath)",
                "--no-border",
                "--no-osc",
                "--no-osd-bar",
                "--keep-open=yes",
                "--idle=yes",
                "--force-window=yes",
                "--hwdec=auto",
                url.absoluteString
            ]

            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                print("DEBUG: mpv process started, PID: \(process.processIdentifier)")

                // Wait for socket and connect in background
                Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                    await self?.connectToMpv(socketPath: socketPath, process: process)
                }
            } catch {
                print("DEBUG: Failed to launch mpv: \(error)")
            }
        }

        private nonisolated func connectToMpv(socketPath: String, process: Process) async {
            var attempts = 0
            while !FileManager.default.fileExists(atPath: socketPath) && attempts < 20 {
                usleep(100_000)
                attempts += 1
            }

            guard FileManager.default.fileExists(atPath: socketPath) else {
                print("DEBUG: mpv socket not created")
                return
            }

            let controller = JsonIpcMpvController(socketPath: socketPath, process: process)
            do {
                try controller.connect()
                self.mpvController = controller
                print("DEBUG: Connected to mpv IPC")

                // Start position polling on main actor
                await MainActor.run { [weak self] in
                    self?.startPositionTimer()
                }
            } catch {
                print("DEBUG: Failed to connect to mpv: \(error)")
            }
        }

        private func startPositionTimer() {
            positionTimer?.invalidate()
            positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updatePosition()
            }
        }

        private func updatePosition() {
            guard let controller = mpvController else { return }

            if let position = try? controller.getPosition() {
                currentTimeBinding.wrappedValue = position
            }

            if let dur = try? controller.getDuration() {
                durationBinding.wrappedValue = dur
            }

            if let paused = try? controller.isPaused() {
                isPlayingBinding.wrappedValue = !paused
            }
        }

        func play() {
            try? mpvController?.resume()
        }

        func pause() {
            try? mpvController?.pause()
        }

        func togglePause() {
            try? mpvController?.togglePause()
        }

        func seek(to time: TimeInterval) {
            try? mpvController?.seek(to: time)
        }

        func stop() {
            positionTimer?.invalidate()
            positionTimer = nil
            mpvController?.quit()
            mpvController = nil
        }

        nonisolated deinit {
            mpvController?.quit()
        }
    }
}

/// Container view for mpv embedding
class MpvContainerView: NSView {
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure layer-backing
        wantsLayer = true
    }
}

/// Simple JSON IPC controller for embedded mpv
class JsonIpcMpvController {
    private let socketPath: String
    private var socketFD: Int32 = -1
    private var process: Process?
    private var requestId: Int = 0

    init(socketPath: String, process: Process) {
        self.socketPath = socketPath
        self.process = process
    }

    func connect() throws {
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw MpvEmbedError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            pathBytes.withUnsafeBufferPointer { pathBuf in
                let destPtr = UnsafeMutableRawPointer(sunPathPtr)
                    .assumingMemoryBound(to: CChar.self)
                for i in 0..<min(pathBuf.count, 104) {
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
            throw MpvEmbedError.connectionFailed
        }
    }

    func getPosition() throws -> TimeInterval {
        let response = try sendCommand(["get_property", "time-pos"])
        if let data = response["data"] as? Double {
            return data
        }
        return 0
    }

    func getDuration() throws -> TimeInterval {
        let response = try sendCommand(["get_property", "duration"])
        if let data = response["data"] as? Double {
            return data
        }
        return 0
    }

    func isPaused() throws -> Bool {
        let response = try sendCommand(["get_property", "pause"])
        if let data = response["data"] as? Bool {
            return data
        }
        return true
    }

    func pause() throws {
        _ = try sendCommand(["set_property", "pause", true])
    }

    func resume() throws {
        _ = try sendCommand(["set_property", "pause", false])
    }

    func togglePause() throws {
        let paused = try isPaused()
        if paused {
            try resume()
        } else {
            try pause()
        }
    }

    func seek(to time: TimeInterval) throws {
        _ = try sendCommand(["seek", time, "absolute"])
    }

    func quit() {
        _ = try? sendCommand(["quit"])
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    @discardableResult
    private func sendCommand(_ command: [Any]) throws -> [String: Any] {
        guard socketFD >= 0 else {
            throw MpvEmbedError.notConnected
        }

        requestId += 1
        let message: [String: Any] = [
            "command": command,
            "request_id": requestId
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        var jsonString = String(data: jsonData, encoding: .utf8)! + "\n"

        let sent = jsonString.withUTF8 { buffer in
            write(socketFD, buffer.baseAddress, buffer.count)
        }
        guard sent > 0 else {
            throw MpvEmbedError.sendFailed
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(socketFD, &buffer, buffer.count)
            if bytesRead <= 0 {
                throw MpvEmbedError.receiveFailed
            }
            responseData.append(contentsOf: buffer[0..<bytesRead])
            if buffer[bytesRead - 1] == 0x0A {
                break
            }
        }

        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MpvEmbedError.invalidResponse
        }

        return response
    }

    deinit {
        quit()
    }
}

enum MpvEmbedError: Error {
    case socketCreationFailed
    case connectionFailed
    case notConnected
    case sendFailed
    case receiveFailed
    case invalidResponse
}
