# Design: Player Abstraction Architecture

## Overview

This document captures the architectural design for abstracting player control behind a unified protocol interface.

## Current Architecture

```
TranscoderTUI
  ├─ useMpv: Bool flag
  ├─ mpvController?: MpvController (optional)
  ├─ server: TranscodeServer
  └─ intendedPauseState: Bool (local tracking)

Control flow:
  if useMpv {
    mpv.getPosition() → display
    mpv.isPaused() → display
  } else {
    server.currentPosition → display
    server.isPaused → display
  }
```

**Issues:**
- Branching logic throughout TUI code
- State tracked in multiple places (mpv, server, TUI)
- Cannot use Chromecast with TUI controls

## Proposed Architecture

```
TranscoderTUI
  └─ player: Player protocol

Player Protocol (defines interface)
  ├─ getPosition() throws -> TimeInterval
  ├─ isPaused() throws -> Bool
  ├─ pause() throws
  ├─ resume() throws
  ├─ seek(to: TimeInterval) throws
  └─ reload(url: URL) throws

Implementations:
  ├─ MpvPlayer: Player
  │   └─ wraps MpvController
  ├─ ChromecastPlayer: Player
  │   └─ wraps CastV2Client + parses MEDIA_STATUS
  └─ ServerPlayer: Player
      └─ wraps TranscodeServer (fallback)
```

**Benefits:**
- Single code path in TUI
- Player is source of truth (what user sees)
- Chromecast can use TUI controls
- Clean separation of concerns

## Protocol Design

```swift
public protocol Player {
    /// Get current playback position in seconds
    func getPosition() throws -> TimeInterval

    /// Get playback duration in seconds
    func getDuration() throws -> TimeInterval

    /// Check if currently paused
    func isPaused() throws -> Bool

    /// Pause playback
    func pause() throws

    /// Resume playback
    func resume() throws

    /// Seek to absolute position in seconds
    func seek(to time: TimeInterval) throws

    /// Reload stream at given URL (for seek with stream restart)
    func reload(url: URL) throws
}
```

### Error Handling

All Player methods throw errors when state is unavailable. TUI catches errors and uses last-known device state or displays error indicator (`--:--:--`). Server state is NEVER used as UI fallback.

### Source of Truth Philosophy

**Device = What user sees/hears (reality)**
- Position: actual playback on screen/speakers
- Pause state: whether audio/video is currently playing
- Player represents REALITY of what the device is doing

**Server = What encoder produces (internal)**
- Position: PTS of last encoded packet (~10s ahead due to buffering)
- Pause state: whether FFmpeg is running (SIGSTOP vs SIGCONT)
- Server state is INTERNAL, not shown in UI

**TUI must reflect reality, not internal state.**

Following VLC's proven Chromecast integration pattern:
- Player is the **ONLY** source for UI position and pause state
- Server methods are **command-only** (pause/resume/seek)
- NO fallback to server state for UI display
- On player error: show last-known state or `--:--:--`

## Implementation Details

### MpvPlayer

Thin wrapper around existing MpvController:

```swift
public final class MpvPlayer: Player {
    private let controller: MpvController

    public func getPosition() throws -> TimeInterval {
        try controller.getPosition()
    }

    public func isPaused() throws -> Bool {
        try controller.isPaused()
    }

    // ... delegates all methods to controller
}
```

**No changes to MpvController** - keeps it stable and tested.

### ChromecastPlayer

Parses MEDIA_STATUS from CastV2Client:

```swift
public final class ChromecastPlayer: Player {
    private let client: CastV2Client
    private var lastStatus: MediaStatus?

    public func getPosition() throws -> TimeInterval {
        guard let status = lastStatus else {
            throw PlayerError.statusUnavailable
        }
        return status.currentTime
    }

    public func isPaused() throws -> Bool {
        guard let status = lastStatus else {
            throw PlayerError.statusUnavailable
        }
        return status.playerState == .PAUSED
    }

    // ... control methods send Cast commands
}
```

**Requires**: Adding MediaStatus parsing to CastV2Client to expose:
- `currentTime: TimeInterval`
- `playerState: PlayerState` (PLAYING, PAUSED, BUFFERING, IDLE)
- `duration: TimeInterval`

### ServerPlayer (Fallback)

Uses TranscodeServer state directly:

```swift
public final class ServerPlayer: Player {
    private let server: TranscodeServer

    public func getPosition() throws -> TimeInterval {
        server.currentPosition
    }

    public func isPaused() throws -> Bool {
        server.isPaused
    }

    // ... control methods delegate to server
}
```

## TUI Refactoring

### Before
```swift
if useMpv, let mpv = mpvController {
    let pos = try? mpv.getPosition()
    let actual = lastSeekPosition + (pos ?? 0)
    return actual
} else {
    return server.currentPosition
}
```

### After
```swift
// Cache last known state
private var lastKnownPosition: TimeInterval = 0.0
private var lastKnownPaused: Bool = false

// Query player exclusively
do {
    let position = try player.getPosition()
    lastKnownPosition = position  // Update cache
    return position
} catch {
    // Use last-known state (NOT server.currentPosition)
    return lastKnownPosition  // or display --:--:-- in UI
}
```

**Device-authoritative**: Player is sole UI source, last-known state on error, no server fallback.

## Position Calculation Strategy

**Issue**: After seek with stream reload, mpv's `playback-time` resets to 0.

**Current approach**: TUI calculates `lastSeekPosition + playbackTime`

**With abstraction**: Move this logic into MpvPlayer implementation:
- MpvPlayer tracks `lastSeekTarget` internally
- Returns `lastSeekTarget + controller.getPosition()`
- TUI doesn't need to know about this quirk

**Result**: TUI just calls `player.getPosition()` and gets correct answer.

## Position Extrapolation (VLC Pattern)

**For smooth UI updates between device queries:**

### MpvPlayer Extrapolation (Optional)
```swift
private var lastDevicePosition: TimeInterval = 0
private var lastQueryTime: Date = Date()

func getPosition() throws -> TimeInterval {
    // Option 1: Query every time (simple, reactive)
    let pos = try controller.getPosition()
    return lastSeekTarget + pos

    // Option 2: Extrapolate between queries (smooth, like VLC)
    let elapsed = Date().timeIntervalSince(lastQueryTime)
    return lastSeekTarget + lastDevicePosition + elapsed
    // Periodically refresh lastDevicePosition from controller
}
```

### ChromecastPlayer Extrapolation (Following VLC's 4s poll)
```swift
private var lastStatusTime: Date?
private var lastDeviceTime: TimeInterval = 0

func getPosition() throws -> TimeInterval {
    guard let status = latestMediaStatus else { throw PlayerError.statusUnavailable }

    // If PLAYING, extrapolate
    if status.playerState == .PLAYING {
        let elapsed = Date().timeIntervalSince(lastStatusTime ?? Date())
        return status.currentTime + elapsed
    }

    // If PAUSED, return exact value
    return status.currentTime
}

// Periodic polling (like VLC's 4-second interval)
func startStatusPolling() {
    // Send GET_STATUS every 4s when playing
}
```

**Benefits**:
- Smooth position updates in UI
- Reduces query frequency (less IPC overhead)
- Matches VLC's proven approach

## Chromecast MEDIA_STATUS

Cast V2 protocol sends unsolicited MEDIA_STATUS messages with:

```json
{
  "type": "MEDIA_STATUS",
  "status": [{
    "mediaSessionId": 1,
    "currentTime": 123.45,
    "playerState": "PLAYING",
    "duration": 3600.0
  }]
}
```

**Implementation**:
1. CastV2Client stores latest MediaStatus
2. ChromecastPlayer queries it via public getter
3. No active polling required (status pushed by Chromecast)

## Migration Strategy

1. **Add Player protocol** (new file, no existing code changes)
2. **Implement MpvPlayer** (wraps MpvController, no changes to controller)
3. **Add MediaStatus to CastV2Client** (parse and store, expose getter)
4. **Implement ChromecastPlayer** (uses MediaStatus)
5. **Implement ServerPlayer** (wraps TranscodeServer)
6. **Refactor TUI** (replace `useMpv` conditionals with `player` calls)
7. **Remove old fields** (`useMpv`, `mpvController`, `intendedPauseState`)

**Rollback safety**: Keep MpvController unchanged, can revert by removing protocol layer.

## Testing Approach

1. **Unit tests**: Each Player implementation
   - Mock underlying components (MpvController, CastV2Client, TranscodeServer)
   - Verify protocol methods delegate correctly
2. **Integration tests**: TUI with each player type
   - Verify seek, pause, position queries work
   - Test rapid key presses (no state corruption)
3. **Manual testing**: Actual devices
   - mpv IPC on macOS
   - Physical Chromecast device

## Open Questions

1. **Should Player be class or protocol?**
   - **Recommendation**: Protocol with class implementations (allows testing with mocks)

2. **How to handle player unavailability?**
   - **Recommendation**: Methods throw errors, TUI catches and uses server fallback

3. **Should we track pause state in Player or TUI?**
   - **Recommendation**: Player queries actual state, TUI doesn't track (simpler)

4. **What about seek during paused?**
   - **Recommendation**: Player handles internally (MpvPlayer restores pause after reload)
