# Beamy Chromecast Implementation - Future Improvements

## Current State: 7/10 - Solid, Functional

The Chromecast implementation works correctly with direct TLS connection (aligned with VLC, PyChromecast, node-castv2).

---

## Priority Improvements

### 1. Async/Await Migration (Medium Priority)

**Current:** Uses `DispatchSemaphore` + `Thread.sleep` which blocks threads.

**Problem:** Blocking inside Swift's cooperative thread pool can cause thread starvation under load.

```swift
// Current (blocking)
let semaphore = DispatchSemaphore(value: 0)
connection?.start(queue: .global())
let result = semaphore.wait(timeout: .now() + 10)

// Better (async)
try await withCheckedThrowingContinuation { continuation in
    connection?.stateUpdateHandler = { state in
        switch state {
        case .ready: continuation.resume()
        case .failed(let error): continuation.resume(throwing: error)
        }
    }
}
```

**Files:** `CastV2Client.swift`

---

### 2. Connection Health Monitoring (Medium Priority)

**Current:** Disconnection only detected when next command fails.

**Problem:** User doesn't know Chromecast died until they try to control it.

**Solution:** Track heartbeat timestamps and notify on stale connection.

```swift
private var lastPingReceived: Date?

case "PING":
    lastPingReceived = Date()
    // ... respond with PONG

// Periodic check
if Date().timeIntervalSince(lastPingReceived) > 15 {
    onDisconnect?(.connectionLost)
}
```

**Files:** `CastV2Client.swift`, `CastingViewModel.swift`

---

### 3. Remove Dead Code (Low Priority)

**Current:** `Caster.swift` (154 lines) appears unused - legacy HTTP-based approach.

**Action:** Delete or document if intentionally kept for reference.

**Files:** `Sources/BeamyKit/Chromecast/Caster.swift`

---

### 4. SwiftProtobuf Migration (Low Priority)

**Current:** Hand-rolled protobuf encoding/decoding.

**Problem:** Fragile if Google changes protocol; hard to maintain.

**Solution:** Use SwiftProtobuf with official `.proto` definitions.

```swift
// Current (manual bytes)
data.append(contentsOf: [0x08, 0x00]) // field 1, varint 0

// Better (generated code)
var message = CastMessage()
message.protocolVersion = .castv2_1_0
message.sourceID = "sender-0"
```

**Files:** `CastV2Client.swift`

---

### 5. Production Logging (Low Priority)

**Current:** Verbose file logging to `/tmp` in all builds.

**Problem:** Disk I/O on every message, no log rotation, privacy concerns.

**Solution:** Use OSLog with privacy controls, disable in release builds.

```swift
import OSLog
private let logger = Logger(subsystem: "com.beamy", category: "chromecast")

logger.debug("Connected to \(device.address, privacy: .private)")
```

**Files:** `CastV2Client.swift`

---

## Nice-to-Have

- **Auto-reconnect:** Attempt reconnection on transient failures
- **Event-driven status:** Replace polling with callbacks from message handler
- **AsyncStream for messages:** Use `AsyncStream` for receiving cast messages

---

## References

- VLC Chromecast: https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/
- PyChromecast: https://github.com/home-assistant-libs/pychromecast/
- node-castv2: https://github.com/thibauts/node-castv2
