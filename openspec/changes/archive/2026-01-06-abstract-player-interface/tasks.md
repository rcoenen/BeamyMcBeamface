# Tasks: Abstract Player Interface

## Phase 0: Spec and Contract Alignment

### A. Clarify Player contract and specs
- [x] Add spec delta files under `openspec/changes/abstract-player-interface/specs/` covering Player abstraction and Chromecast status exposure
- [x] Document Player method semantics: synchronous command vs applied-state guarantees, time units (seconds), and thread-safety expectations
- [x] Define `PlayerError` cases and mapping from Mpv/Cast/Server failures (e.g., statusUnavailable, unsupportedOperation, commandFailed, disconnected)
- [x] Document lifecycle ownership: who creates/tears down each player (mpv launch, Cast connect/load, server), and how reload semantics differ per player
- [x] Clarify Cast status freshness: when `latestMediaStatus` populates, how duration/currentTime are derived, and fallback/staleness handling

## Phase 1: Protocol and Base Infrastructure

### 1. Define Player protocol
- [x] Create `Sources/BeamyKit/Player/Player.swift`
- [x] Define protocol with methods: `getPosition()`, `getDuration()`, `isPaused()`, `pause()`, `resume()`, `seek(to:)`, `reload(url:)`
- [x] Define `PlayerError` enum for common error cases
- [x] Add documentation comments to protocol methods
- **Validation**: Protocol compiles, no implementation yet

### 2. Add MediaStatus to CastV2Client
- [x] Create `MediaStatus` struct in `Sources/BeamyKit/Chromecast/MediaStatus.swift`
- [x] Add fields: `currentTime: TimeInterval`, `playerState: PlayerState`, `duration: TimeInterval`, `mediaSessionId: Int`
- [x] Define `PlayerState` enum: `PLAYING`, `PAUSED`, `BUFFERING`, `IDLE`
- [x] Add `latestMediaStatus: MediaStatus?` property to CastV2Client
- [x] Parse MEDIA_STATUS messages in `handleMessage()` and update property
- **Validation**: CastV2Client exposes parsed status, existing functionality unchanged

## Phase 2: Player Implementations

### 3. Implement ServerPlayer
- [x] (Removed) ServerPlayer no longer needed; TUI requires real player device (mpv/Chromecast)

### 4. Implement MpvPlayer
- [x] Create `Sources/BeamyKit/Player/MpvPlayer.swift`
- [x] Add `lastSeekTarget: TimeInterval` tracking field
- [x] Implement `getPosition()` as `lastSeekTarget + controller.getPosition()`
- [x] Implement `isPaused()` delegating to `controller.isPaused()`
- [x] Implement `pause()`, `resume()` delegating to controller
- [x] Implement `seek(to:)` updating `lastSeekTarget` then calling `controller.seek(to:)`
- [x] Implement `reload(url:)` delegating to `controller.reloadStream(url)`
- [x] Add pause state preservation logic in `seek(to:)` and `reload(url:)`
- **Validation**: MpvPlayer wraps MpvController without modifying it, position calculation correct

### 5. Implement ChromecastPlayer
- [x] Create `Sources/BeamyKit/Player/ChromecastPlayer.swift`
- [x] Store reference to CastV2Client
- [x] Implement `getPosition()` reading `client.latestMediaStatus?.currentTime`
- [x] Implement `getDuration()` reading `client.latestMediaStatus?.duration`
- [x] Implement `isPaused()` checking if `playerState == .PAUSED`
- [x] Implement `pause()` sending PAUSE command via client
- [x] Implement `resume()` sending PLAY command via client
- [x] Implement `seek(to:)` sending SEEK command via client
- [x] Throw `PlayerError.statusUnavailable` when `latestMediaStatus` is nil
- **Validation**: ChromecastPlayer compiles, methods use MediaStatus correctly

## Phase 3: TUI Refactoring

### 6. Add Player factory to TUI initialization
- [x] Add `player: Player` property to TranscoderTUI
- [x] Remove `useMpv: Bool`, `mpvController: MpvController?`, `intendedPauseState: Bool` fields
- [x] Update `init()` to accept `player: Player` parameter instead of `useMpv`
- [x] Update TUI creation in TranscodeTest command to pass appropriate Player instance
- **Validation**: TUI compiles with new initialization, old fields removed

### 7. Refactor getCurrentPosition() to use Player
- [x] Replace `if useMpv { ... } else { ... }` with `try? player.getPosition()`
- [x] Remove `lastSeekPosition + playbackTime` calculation (now in MpvPlayer)
- [x] Use last-known player position on error (no server fallback)
- [x] Remove `isSeekInProgress` check (if MpvPlayer handles it internally)
- **Validation**: Position display works identically for mpv mode

### 8. Refactor getIsPaused() to use Player
- [x] Replace `if useMpv { ... } else { ... }` with `try? player.isPaused()`
- [x] Use last-known player pause state on error (no server fallback)
- [x] Remove `pauseStateDuringSeek` logic (if no longer needed)
- **Validation**: Pause icon displays correctly, no flicker during seeks

### 9. Refactor togglePlayPause() to use Player
- [x] Replace `if useMpv { ... } else { ... }` with Player calls
- [x] Use `try player.isPaused()` then `try player.pause()` or `try player.resume()`
- [x] Remove `intendedPauseState` tracking
- [x] Use player state only; no server-driven UI fallback
- **Validation**: Space bar toggles pause/play correctly for mpv

### 10. Refactor seek() to use Player
- [x] Remove mpv-specific reload logic
- [x] Call `try player.seek(to: time)` instead of `if useMpv { ... }`
- [x] Remove `lastSeekPosition`, `lastSeekTime` tracking (if MpvPlayer handles it)
- [x] Let Player handle pause preservation
- [x] Add error handling
- **Validation**: Arrow keys seek correctly, pause state preserved for mpv

### 11. Remove remaining useMpv conditionals
- [x] Search codebase for `useMpv` references
- [x] Replace with Player protocol calls or remove
- [x] Update `drawUI()` player mode display to query player type if needed
- [x] Remove `launchMpv()` if no longer needed (or move to Player factory)
- **Validation**: Zero `useMpv` references in TUI code

## Phase 4: Testing and Validation

### 12. Test MpvPlayer with rapid seeks
- [x] Run TUI with mpv mode
- [x] Hammer arrow keys rapidly
- [x] Verify position doesn't jump erratically
- [x] Verify pause state preserved correctly (observed <2s drift under heavy seeking, recovers)
- **Validation**: Rapid seeks work as well or better than before refactor

### 13. Test ServerPlayer fallback mode
- [ ] (Removed) ffplay/ServerPlayer fallback no longer supported in TUI

### 14. Add Chromecast mode to transcode-test command (if in scope)
- [x] Add `--chromecast <device-id>` option to TranscodeTest command
- [x] Create ChromecastPlayer instance when flag provided
- [x] Pass to TUI
- [ ] Test with physical Chromecast device
- **Validation**: TUI controls Chromecast, displays actual playback position

### 15. Add unit tests for Player implementations
- [x] Test MpvPlayer calculates position correctly after seek
- [x] Test ChromecastPlayer parses MediaStatus correctly
- [x] Test error handling in all implementations
- **Validation**: All tests pass (3/3)

### 16. Update documentation
- [x] Add Player protocol documentation
- [x] Update README if Player abstraction affects user-visible behavior
- [x] Add code comments explaining position calculation in MpvPlayer
- **Validation**: Documentation is clear and accurate

## Dependencies

- **Parallel work**: Tasks 3, 4, 5 (Player implementations) can be done in parallel
- **Blocking**: Task 6 must complete before 7-11 (need Player in TUI first)
- **Sequential**: Tasks 7-11 should be done in order (each refactors one method)
- **Final**: Tasks 12-16 validate the complete implementation

## Out of Scope (Future Work)

- Server-side seek synchronization (Chromecast seeking the transcoder)
- Multi-player support (simultaneous mpv + Chromecast)
- Player state persistence across TUI restarts
- Advanced error recovery (auto-reconnect on player failure)
