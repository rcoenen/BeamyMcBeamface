# Design: Harden Chromecast Playback

## Architectural Patterns

This change applies three proven reliability patterns to the Chromecast stack:

### 1. Thread-Safe State Pattern

**Problem**: Shared mutable state accessed from multiple threads without synchronization.

**Current (unsafe)**:
```swift
// CastV2Client.swift
public private(set) var latestMediaStatus: MediaStatus?  // ❌ Unsafe

// Network thread writes:
self.latestMediaStatus = parsedStatus

// Main thread reads:
guard let status = statusProvider() else { ... }  // ❌ Race!
```

**Solution**: Serial dispatch queue or NSLock wrapper
```swift
private let statusQueue = DispatchQueue(label: "com.beamy.chromecast.status")
private var _latestMediaStatus: MediaStatus?

public var latestMediaStatus: MediaStatus? {
    statusQueue.sync { _latestMediaStatus }
}

private func updateStatus(_ status: MediaStatus) {
    statusQueue.sync { _latestMediaStatus = status }
}
```

**Trade-offs**:
- ✅ Simple, proven pattern (same as DiscoveryState)
- ✅ Zero risk of torn reads
- ⚠️ Slight overhead (sync call, but negligible for infrequent reads)

**Alternative considered**: `@MainActor` - Rejected because network callbacks run on global queue, can't easily marshal to main actor.

---

### 2. Async Command Completion Pattern

**Problem**: Blocking sleeps wait for unknown duration, freeze UI.

**Current (blocking)**:
```swift
try client.loadMedia(...)
Thread.sleep(forTimeInterval: 1.0)  // ❌ Blocks for 1s!
```

**Solution**: Callback-based completion with timeout
```swift
func loadMedia(..., completion: @escaping (Result<Void, Error>) -> Void) {
    // Send LOAD message
    try sendMessage(...)

    // Wait for MEDIA_STATUS with timeout
    waitForMediaStatus(timeout: 5.0) { result in
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

private func waitForMediaStatus(timeout: TimeInterval, completion: @escaping (Result<MediaStatus, Error>) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    var observer: (() -> Void)?

    observer = {
        statusQueue.sync {
            if let status = self._latestMediaStatus {
                completion(.success(status))
                observer = nil
            } else if Date() > deadline {
                completion(.failure(CastV2Error.timeout))
                observer = nil
            } else {
                // Poll again in 100ms
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: observer!)
            }
        }
    }
    observer?()
}
```

**Trade-offs**:
- ✅ Non-blocking, UI stays responsive
- ✅ Definite timeout (5s max wait)
- ⚠️ Adds callback complexity
- ⚠️ Polling is less elegant than true observer pattern

**Alternative considered**: Combine publishers - Rejected to avoid adding dependency.

---

### 3. Validated State Transition Pattern

**Problem**: Commands sent but not verified, leading to state inconsistency.

**Current (fire-and-forget)**:
```swift
try player.seek(to: 120.0)
// Did it work? Who knows!
```

**Solution**: Validate state after command
```swift
func seek(to time: TimeInterval) throws {
    let beforeState = try currentStatus()
    try commandSender("SEEK", beforeState.mediaSessionId, ["currentTime": time])

    // Wait for confirmation (up to 3 seconds)
    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline {
        if let status = statusProvider(),
           abs(status.currentTime - time) < 2.0 {
            return  // ✅ Seek confirmed
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    // Timeout - log warning but don't fail
    log("Warning: Seek to \(time)s not confirmed within 3s")
}
```

**Trade-offs**:
- ✅ Detects failed commands
- ✅ Provides feedback to user
- ⚠️ Adds latency (100-300ms typically)
- ⚠️ Still uses polling (better than nothing)

**Alternative considered**: Promise-based API - Deferred to future work.

---

## Component Changes

### CastV2Client

**Before**:
```
┌─────────────────────────────┐
│  CastV2Client               │
│  - latestMediaStatus (raw)  │  ← ❌ Unsafe
│  - sendMediaCommand()       │  ← ❌ Blocking
│  - Thread.sleep()           │  ← ❌ Freezes UI
└─────────────────────────────┘
```

**After**:
```
┌─────────────────────────────┐
│  CastV2Client               │
│  - statusQueue: DispatchQ   │  ← ✅ Thread-safe
│  - _latestMediaStatus       │  ← ✅ Private
│  - latestMediaStatus (prop) │  ← ✅ Synchronized getter
│  - loadMedia(completion:)   │  ← ✅ Async
│  - sendMediaCommand(compl:) │  ← ✅ Async
│  - waitForMediaStatus()     │  ← ✅ Polling helper
└─────────────────────────────┘
```

### ChromecastPlayer

**Minimal changes** - just update to use async APIs:
```swift
public func seek(to time: TimeInterval) throws {
    let status = try currentStatus()

    // Before: Fire and forget
    // try commandSender("SEEK", status.mediaSessionId, ["currentTime": time])

    // After: Validate completion
    try commandSenderWithValidation("SEEK", status.mediaSessionId, ["currentTime": time], expectedTime: time)
}
```

### TermKitTranscoderUI

**Add switching state**:
```swift
private var isSwitchingOutput = false

private func applyOutputChoice(...) {
    guard !isSwitchingOutput else {
        log("Output switch already in progress")
        return
    }

    isSwitchingOutput = true
    statusLabel?.text = "Status: switching output..."

    // ... perform switch ...

    isSwitchingOutput = false
}
```

**Validate position after switch**:
```swift
// After launching new player
let newPosition = try? player.getPosition()
if let newPos = newPosition, abs(newPos - lastKnownPosition) > 2.0 {
    log("Warning: Position drift after switch: expected \(lastKnownPosition)s, got \(newPos)s")
}
```

---

## Position Tracking Architecture

### Current Flow (Reactive)

```
Chromecast sends MEDIA_STATUS (every 1-3s)
    ↓
CastV2Client receives message
    ↓
latestMediaStatus updated
    ↓
TUI timer (every 0.5s) calls getPosition()
    ↓
Returns stale value (0-3s old)
```

**Problem**: Up to 3 seconds of staleness.

### New Flow (Active Polling)

```
TUI timer (every 0.5s)
    ↓
Check if playing Chromecast
    ↓
Request fresh position via GET_STATUS command
    ↓
Chromecast responds with current MEDIA_STATUS
    ↓
Returns fresh value (<100ms old)
```

**Benefits**:
- ✅ Always fresh (within 500ms)
- ✅ Smooth progress bar
- ✅ Accurate time display

**Cost**:
- ⚠️ Extra network round-trip every 0.5s (minimal overhead)

**Alternative** (interpolation):
```swift
func getPosition() throws -> TimeInterval {
    guard let status = statusProvider() else {
        throw PlayerError.statusUnavailable
    }

    // If playing, interpolate based on elapsed time
    if status.playerState == .playing {
        let elapsed = Date().timeIntervalSince(statusTimestamp)
        return status.currentTime + elapsed
    }

    return status.currentTime
}
```

**Decision**: Use polling first (simpler), add interpolation if network overhead becomes issue.

---

## Error Handling Strategy

### Command Failure Classification

1. **Network Errors** (connection lost)
   - Action: Fail fast, disconnect, revert to mpv
   - User feedback: "Chromecast disconnected"

2. **Timeout Errors** (no response in 5s)
   - Action: Retry once, then log warning
   - User feedback: Continue playback, log to file

3. **State Errors** (no session/transport ID)
   - Action: Attempt reconnect once
   - User feedback: "Reconnecting to Chromecast..."

4. **Validation Errors** (seek didn't reach target)
   - Action: Log warning, continue
   - User feedback: None (non-critical)

### Retry Logic

```swift
func sendCommandWithRetry(type: String, maxRetries: Int = 1) throws {
    var attempt = 0
    var lastError: Error?

    while attempt <= maxRetries {
        do {
            try sendMediaCommand(type: type) { result in
                switch result {
                case .success: return
                case .failure(let error): throw error
                }
            }
            return  // Success
        } catch {
            lastError = error
            attempt += 1
            if attempt <= maxRetries {
                log("Retry \(attempt)/\(maxRetries) for \(type) command")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    throw lastError ?? PlayerError.commandFailed("Unknown error")
}
```

---

## Migration Strategy

### Phase 1: Thread Safety (Non-Breaking)

- Add `statusQueue` to CastV2Client
- Wrap `latestMediaStatus` access
- No API changes
- Test: Rapid seek/pause cycles

### Phase 2: Async Commands (Breaking)

- Add `completion:` parameters to commands
- Keep blocking versions temporarily for compatibility
- Update TermKitTranscoderUI to use async versions
- Remove blocking versions after testing

### Phase 3: Validation (Additive)

- Add validation loops after commands
- Log warnings, don't fail
- Gradually tighten validation criteria
- Add metrics for validation failures

---

## Performance Considerations

**Memory**: Negligible (<1KB overhead for dispatch queue)

**CPU**: Polling adds ~0.1% CPU (1 round-trip per 0.5s)

**Network**: Extra ~200 bytes/s during playback (GET_STATUS requests)

**Latency**: Commands respond faster (no 1s sleep!) but add 100-300ms validation

**Overall**: Net positive - UI more responsive despite validation overhead.
