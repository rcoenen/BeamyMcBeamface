import Foundation
import Network

/// Cast V2 Protocol client for communicating with Chromecast devices
/// Protocol: TLS on port 8009, protobuf message framing, JSON payloads
public final class CastV2Client: @unchecked Sendable {
    private let device: ChromecastDevice
    private var connection: NWConnection?
    private var transportId: String?
    private var sessionId: String?
    private var mediaSessionId: Int?
    public private(set) var latestMediaStatus: MediaStatus?
    private var requestId: Int = 0
    private let verbose: Bool
    private let logURL = URL(fileURLWithPath: "/tmp/beamy-cast.log")

    // Cast namespaces
    private let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private let nsMedia = "urn:x-cast:com.google.cast.media"

    // Default Media Receiver app ID
    private let defaultMediaReceiverAppId = "CC1AD845"

    public init(device: ChromecastDevice, verbose: Bool = true) {
        self.device = device
        self.verbose = verbose
        if verbose {
            // Create log file on init
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
        }
    }

    public func log(_ message: String) {
        if verbose {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    public func connect() throws {
        log("Connecting to \(device.address):8009 via TLS...")

        let host = NWEndpoint.Host(device.address)
        let port = NWEndpoint.Port(integerLiteral: 8009)

        // Create TLS parameters - Chromecast uses self-signed certs
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (_, _, completionHandler) in
            // Accept any certificate (Chromecast uses self-signed)
            completionHandler(true)
        }, DispatchQueue.global())

        let params = NWParameters(tls: tlsOptions)
        connection = NWConnection(host: host, port: port, using: params)

        let semaphore = DispatchSemaphore(value: 0)

        // Use a class wrapper for thread-safe error capture
        final class ErrorBox: @unchecked Sendable {
            var error: Error?
        }
        let errorBox = ErrorBox()

        connection?.stateUpdateHandler = { [weak self, errorBox] state in
            switch state {
            case .ready:
                self?.log("TLS connection established")
                semaphore.signal()
            case .failed(let error):
                self?.log("Connection failed: \(error)")
                errorBox.error = error
                semaphore.signal()
            case .cancelled:
                self?.log("Connection cancelled")
                semaphore.signal()
            default:
                self?.log("Connection state: \(state)")
            }
        }

        connection?.start(queue: .global())

        let result = semaphore.wait(timeout: .now() + 10)
        if result == .timedOut {
            throw CastV2Error.connectionTimeout
        }
        if let error = errorBox.error {
            throw CastV2Error.connectionFailed(error.localizedDescription)
        }

        // Start receiving messages
        startReceiving()

        // Send initial CONNECT to receiver
        log("Sending CONNECT to receiver...")
        try sendMessage(
            namespace: nsConnection,
            destinationId: "receiver-0",
            payload: ["type": "CONNECT"]
        )

        // Small delay for connection to establish
        Thread.sleep(forTimeInterval: 0.5)

        log("Connected to Chromecast!")
    }

    public func launchDefaultMediaReceiver() throws {
        log("Launching Default Media Receiver (CC1AD845)...")

        requestId += 1
        try sendMessage(
            namespace: nsReceiver,
            destinationId: "receiver-0",
            payload: [
                "type": "LAUNCH",
                "appId": defaultMediaReceiverAppId,
                "requestId": requestId
            ]
        )

        // Wait for RECEIVER_STATUS with transport ID
        log("Waiting for app to launch and receive transport ID...")
        var waitTime = 0.0
        while transportId == nil && waitTime < 10.0 {
            Thread.sleep(forTimeInterval: 0.1)
            waitTime += 0.1
        }

        guard let actualTransportId = transportId else {
            throw CastV2Error.connectionFailed("Failed to get transport ID from RECEIVER_STATUS")
        }

        log("Using transport ID from RECEIVER_STATUS: \(actualTransportId)")

        // Connect to the launched app
        log("Connecting to media app transport: \(actualTransportId)...")
        try sendMessage(
            namespace: nsConnection,
            destinationId: actualTransportId,
            payload: ["type": "CONNECT"]
        )

        Thread.sleep(forTimeInterval: 0.5)
        log("Media receiver ready")
    }

    public func loadMedia(url: URL, contentType: String, title: String? = nil, isLive: Bool = false) throws {
        guard let transportId = transportId else {
            throw CastV2Error.notConnected
        }

        log("Loading media: \(url.absoluteString)")
        log("Content-Type: \(contentType)")

        requestId += 1

        var metadata: [String: Any] = [:]

        // Determine metadata type and stream type based on content type
        let streamType: String
        if contentType.starts(with: "image/") {
            metadata["metadataType"] = 4 // PHOTO
            streamType = "NONE"
        } else if contentType.starts(with: "video/") {
            metadata["metadataType"] = 1 // MOVIE
            // Use LIVE for transcoded streams (no Content-Length), BUFFERED for files
            streamType = isLive ? "LIVE" : "BUFFERED"
        } else {
            streamType = "BUFFERED"
        }

        if let title = title {
            metadata["title"] = title
        }

        let media: [String: Any] = [
            "contentId": url.absoluteString,
            "contentType": contentType,
            "streamType": streamType,
            "metadata": metadata
        ]

        let payload: [String: Any] = [
            "type": "LOAD",
            "requestId": requestId,
            "media": media,
            "autoplay": true,
            "currentTime": 0
        ]

        log("Sending LOAD message:")
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            log(jsonString)
        }

        try sendMessage(
            namespace: nsMedia,
            destinationId: transportId,
            payload: payload
        )

        log("LOAD message sent, waiting for playback...")
        Thread.sleep(forTimeInterval: 1)
    }

    /// Send a media control command (PLAY, PAUSE, SEEK) to the active session.
    public func sendMediaCommand(type: String, mediaSessionId: Int? = nil, additional: [String: Any] = [:]) throws {
        guard let transportId = transportId else {
            throw CastV2Error.notConnected
        }

        requestId += 1

        var payload = additional
        payload["type"] = type
        payload["requestId"] = requestId

        if let sessionId = mediaSessionId ?? latestMediaStatus?.mediaSessionId ?? self.mediaSessionId {
            payload["mediaSessionId"] = sessionId
        }

        try sendMessage(
            namespace: nsMedia,
            destinationId: transportId,
            payload: payload
        )
    }

    public func disconnect() {
        log("Disconnecting...")

        // Send CLOSE to receiver
        if let transportId = transportId {
            try? sendMessage(
                namespace: nsConnection,
                destinationId: transportId,
                payload: ["type": "CLOSE"]
            )
        }

        try? sendMessage(
            namespace: nsConnection,
            destinationId: "receiver-0",
            payload: ["type": "CLOSE"]
        )

        connection?.cancel()
        connection = nil
        log("Disconnected")
    }

    // MARK: - Private Methods

    private func sendMessage(namespace: String, destinationId: String, payload: [String: Any]) throws {
        guard let connection = connection else {
            throw CastV2Error.notConnected
        }

        // Convert payload to JSON
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw CastV2Error.encodingFailed
        }

        // Build CastMessage (simplified protobuf format)
        // Real implementation would use proper protobuf serialization
        let message = buildCastMessage(
            namespace: namespace,
            sourceId: "sender-0",
            destinationId: destinationId,
            payload: payloadString
        )

        log("TX [\(namespace)] -> \(destinationId): \(payloadString)")

        // Send with length prefix (4 bytes big-endian)
        var length = UInt32(message.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(message)

        let semaphore = DispatchSemaphore(value: 0)
        final class SendErrorBox: @unchecked Sendable {
            var error: Error?
        }
        let sendErrorBox = SendErrorBox()

        connection.send(content: data, completion: .contentProcessed { [sendErrorBox] error in
            if let error = error {
                sendErrorBox.error = error
            }
            semaphore.signal()
        })

        _ = semaphore.wait(timeout: .now() + 5)

        if let error = sendErrorBox.error {
            throw CastV2Error.sendFailed(error.localizedDescription)
        }
    }

    private func buildCastMessage(namespace: String, sourceId: String, destinationId: String, payload: String) -> Data {
        // Simplified protobuf encoding for CastMessage
        // Field 1: protocol_version (varint) = 0 (CASTV2_1_0)
        // Field 2: source_id (string)
        // Field 3: destination_id (string)
        // Field 4: namespace (string)
        // Field 5: payload_type (varint) = 0 (STRING)
        // Field 6: payload_utf8 (string)

        var data = Data()

        // Field 1: protocol_version = 0
        data.append(contentsOf: [0x08, 0x00]) // field 1, varint 0

        // Field 2: source_id
        data.append(0x12) // field 2, length-delimited
        data.append(contentsOf: encodeVarint(sourceId.utf8.count))
        data.append(contentsOf: sourceId.utf8)

        // Field 3: destination_id
        data.append(0x1a) // field 3, length-delimited
        data.append(contentsOf: encodeVarint(destinationId.utf8.count))
        data.append(contentsOf: destinationId.utf8)

        // Field 4: namespace
        data.append(0x22) // field 4, length-delimited
        data.append(contentsOf: encodeVarint(namespace.utf8.count))
        data.append(contentsOf: namespace.utf8)

        // Field 5: payload_type = 0 (STRING)
        data.append(contentsOf: [0x28, 0x00]) // field 5, varint 0

        // Field 6: payload_utf8
        data.append(0x32) // field 6, length-delimited
        data.append(contentsOf: encodeVarint(payload.utf8.count))
        data.append(contentsOf: payload.utf8)

        return data
    }

    private func encodeVarint(_ value: Int) -> [UInt8] {
        var result: [UInt8] = []
        var v = value
        while v >= 0x80 {
            result.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }

    private func startReceiving() {
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        guard let connection = connection else { return }

        // Read 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.log("Receive error: \(error)")
                return
            }

            guard let lengthData = content, lengthData.count == 4 else {
                if !isComplete {
                    self.receiveNextMessage()
                }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Read message body
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] content, _, _, error in
                guard let self = self else { return }

                if let error = error {
                    self.log("Receive body error: \(error)")
                    return
                }

                if let messageData = content {
                    self.handleReceivedMessage(messageData)
                }

                self.receiveNextMessage()
            }
        }
    }

    private func handleReceivedMessage(_ data: Data) {
        // Parse protobuf message (simplified)
        // Look for payload_utf8 field (field 6)
        if let payload = extractPayload(from: data) {
            log("RX: \(payload)")

            // Parse JSON and handle specific messages
            if let jsonData = payload.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                handleJsonMessage(json)
            }
        }
    }

    private func extractPayload(from data: Data) -> String? {
        // Simple protobuf parsing - find field 6 (payload_utf8)
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            offset += 1

            if wireType == 0 { // varint
                while offset < data.count && data[offset] & 0x80 != 0 {
                    offset += 1
                }
                offset += 1
            } else if wireType == 2 { // length-delimited
                var length = 0
                var shift = 0
                while offset < data.count {
                    let byte = data[offset]
                    offset += 1
                    length |= Int(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift += 7
                }

                if fieldNumber == 6 && offset + length <= data.count {
                    let payloadData = data[offset..<(offset + length)]
                    return String(data: payloadData, encoding: .utf8)
                }
                offset += length
            }
        }
        return nil
    }

    private func handleJsonMessage(_ json: [String: Any]) {
        if let type = json["type"] as? String {
            switch type {
            case "PING":
                // Respond with PONG
                try? sendMessage(
                    namespace: nsHeartbeat,
                    destinationId: "receiver-0",
                    payload: ["type": "PONG"]
                )
            case "RECEIVER_STATUS":
                if let status = json["status"] as? [String: Any],
                   let apps = status["applications"] as? [[String: Any]],
                   let app = apps.first {
                    if let newTransportId = app["transportId"] as? String {
                        log("Got transport ID: \(newTransportId)")
                        self.transportId = newTransportId
                    }
                    if let newSessionId = app["sessionId"] as? String {
                        log("Got session ID: \(newSessionId)")
                        self.sessionId = newSessionId
                    }
                }
            case "MEDIA_STATUS":
                if let statuses = json["status"] as? [[String: Any]],
                   let status = statuses.first {
                    if let parsedStatus = MediaStatus(dictionary: status) {
                        log("Updated media status: session \(parsedStatus.mediaSessionId), state \(parsedStatus.playerState.rawValue), currentTime \(parsedStatus.currentTime), duration \(parsedStatus.duration)")
                        self.mediaSessionId = parsedStatus.mediaSessionId
                        self.latestMediaStatus = parsedStatus
                    } else if let newMediaSessionId = (status["mediaSessionId"] as? NSNumber)?.intValue {
                        log("Got media session ID: \(newMediaSessionId)")
                        self.mediaSessionId = newMediaSessionId
                    } else {
                        log("MEDIA_STATUS received but could not parse session/state")
                    }
                }
            case "LOAD_FAILED":
                log("ERROR: Media load failed!")
                if let reason = json["reason"] as? String {
                    log("Reason: \(reason)")
                }
            default:
                break
            }
        }
    }

    deinit {
        disconnect()
    }
}

public enum CastV2Error: Error, CustomStringConvertible {
    case connectionTimeout
    case connectionFailed(String)
    case notConnected
    case encodingFailed
    case sendFailed(String)

    public var description: String {
        switch self {
        case .connectionTimeout:
            return "Connection timed out"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .notConnected:
            return "Not connected to Chromecast"
        case .encodingFailed:
            return "Failed to encode message"
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
