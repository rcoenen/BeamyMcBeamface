# Proposal: Harden Chromecast Playback for V1.0

## Why

The current Chromecast implementation has critical reliability issues that prevent rock-solid video playback and seamless switching between mpv and Chromecast:

### Critical Problems

1. **Thread-Safety Race Condition**
   - `CastV2Client.latestMediaStatus` is written on network thread, read on main thread
   - No synchronization → torn reads, potential crashes, wrong position/state
   - Impact: Random position jumps, `isPaused()` returning incorrect state

2. **Blocking Operations Freeze UI**
   - `Thread.sleep(1.0)` after LOAD command blocks entire TUI
   - `Thread.sleep(0.5)` after app launch blocks UI
   - Impact: Laggy seeking, frozen UI during Chromecast commands

3. **No Command Validation**
   - Commands (PLAY, PAUSE, SEEK) sent fire-and-forget
   - No confirmation that Chromecast executed them
   - Impact: User presses seek → nothing happens → confusion

4. **Output Switching Position Drift**
   - Position queried from old player might throw or return stale value
   - New player seeks but doesn't verify arrival at target position
   - Impact: Switch mpv → Chromecast → video jumps 5 seconds back/forward

5. **Stale Position Updates**
   - Chromecast sends MEDIA_STATUS every 1-3s (not guaranteed)
   - `getPosition()` returns stale data between updates
   - Impact: Progress bar stutters, time display wrong

### User Impact

- **Current**: Chromecast playback works but feels janky
  - Seeking takes 1+ seconds (blocking sleep)
  - Position tracking stutters
  - Switching outputs loses 2-5 seconds of position
  - Random state inconsistencies

- **Target**: Rock-solid playback on par with mpv
  - Instant seeking (<100ms response)
  - Accurate position tracking (±0.5s)
  - Seamless output switching (±1s position accuracy)
  - Reliable state (pause/play always correct)

## What Changes

### Phase 1: Thread Safety & Async Operations (Critical)

**Scope**: CastV2Client, ChromecastPlayer
- Add thread-safe access to `latestMediaStatus` via NSLock or serial queue
- Replace blocking `Thread.sleep()` with async callbacks
- Add command confirmation by waiting for MEDIA_STATUS updates
- Implement timeout-based validation (commands must complete in 5s)

### Phase 2: Output Switching Validation (Important)

**Scope**: TermKitTranscoderUI
- Add "Switching output..." visual feedback during transitions
- Validate position after switch (log warning if >2s drift)
- Robust position extraction with fallbacks (try new player, fallback to lastKnownPosition)
- Add `isSwitchingOutput` state to prevent concurrent switches

### Phase 3: Position Accuracy (Polish)

**Scope**: ChromecastPlayer, TermKitTranscoderUI
- Implement active position polling when playing (query every 1s)
- Add position interpolation (estimate based on last known + elapsed time)
- Reduce reliance on MEDIA_STATUS for critical operations
- Add drift detection (warn if player position differs >3s from server)

## Out of Scope

- Volume control (not needed for V1.0)
- Subtitle/track selection (future feature)
- Queue/playlist support (future feature)
- Unit tests (backlog, not blocking V1.0)
- Reconnection logic (device disconnect mid-stream)

## Success Criteria

1. **Thread Safety**: No race conditions under stress testing (rapid seek/pause/switch)
2. **Responsiveness**: Seeking responds in <200ms (vs current 1000ms)
3. **Accuracy**: Position tracking within ±1s of actual playback
4. **Seamless Switching**: Output switch preserves position within ±2s
5. **Reliability**: 100 sequential play/pause/seek cycles without error

## Risks & Mitigations

- **Risk**: Async callbacks add complexity
  - **Mitigation**: Keep callback model simple (single completion handler per command)

- **Risk**: Position polling increases network traffic
  - **Mitigation**: Only poll when playing, stop when paused

- **Risk**: Breaking existing Chromecast functionality
  - **Mitigation**: Incremental changes, test after each phase

## Dependencies

- No external dependencies
- Builds on existing Player abstraction
- All changes internal to BeamyKit/Chromecast and TermKitTranscoderUI
