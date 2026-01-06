# Tasks: Harden Chromecast Playback

## Phase 1: Thread Safety (Critical - No API Changes)

### 1. Add thread-safe status access to CastV2Client
- [ ] Create `statusQueue: DispatchQueue` property in CastV2Client
- [ ] Rename `latestMediaStatus` to `_latestMediaStatus` (private)
- [ ] Add computed `latestMediaStatus` property with synchronized getter
- [ ] Update `handleJsonMessage()` to use synchronized setter
- [ ] **Validation**: No compiler warnings, existing tests still pass

### 2. Replace blocking sleeps in launchDefaultMediaReceiver()
- [ ] Remove `Thread.sleep(0.5)` after launching receiver app
- [ ] Add `waitForReceiverStatus(timeout:completion:)` helper method
- [ ] Update `launchDefaultMediaReceiver()` to use async wait pattern
- [ ] Add timeout handling (5s max wait)
- [ ] **Validation**: App launch doesn't block UI, still connects successfully

### 3. Replace blocking sleeps in loadMedia()
- [ ] Remove `Thread.sleep(1.0)` after sending LOAD message
- [ ] Add `waitForMediaStatus(timeout:completion:)` helper method
- [ ] Update `loadMedia()` to accept completion handler
- [ ] Poll for MEDIA_STATUS with 100ms interval up to 5s timeout
- [ ] **Validation**: Media loads without blocking, completion fires correctly

### 4. Update ChromecastPlayer to handle async loadMedia()
- [ ] Update `ChromecastPlayer.reload()` to use async `loadMedia(completion:)`
- [ ] Handle completion callback on main thread
- [ ] Maintain backward compatibility (still throws on error)
- [ ] **Validation**: Reload works, UI responsive during load

### 5. Test thread safety under stress
- [ ] Add manual test: rapid seek/pause/play cycles (100x)
- [ ] Monitor for race conditions in logs
- [ ] Verify no crashes or torn reads
- [ ] **Validation**: 100 cycles complete without error

## Phase 2: Command Validation (Adds Reliability)

### 6. Add command validation helper to ChromecastPlayer
- [ ] Create `waitForStatusUpdate(predicate:timeout:)` private method
- [ ] Method polls `latestMediaStatus` every 100ms
- [ ] Returns true if predicate matches within timeout, false otherwise
- [ ] **Validation**: Helper compiles, basic test passes

### 7. Add seek validation
- [ ] Update `ChromecastPlayer.seek(to:)` to validate position after command
- [ ] After sending SEEK, call `waitForStatusUpdate` with predicate: `abs(status.currentTime - targetTime) < 2.0`
- [ ] Timeout after 3 seconds
- [ ] Log warning if validation fails, but don't throw
- [ ] **Validation**: Seek completes faster, logs warning on timeout

### 8. Add pause/resume validation
- [ ] Update `ChromecastPlayer.pause()` to validate `playerState == .paused`
- [ ] Update `ChromecastPlayer.resume()` to validate `playerState == .playing`
- [ ] Timeout after 3 seconds each
- [ ] Log warnings if validation fails
- [ ] **Validation**: Commands confirmed via MEDIA_STATUS updates

### 9. Add retry logic to sendMediaCommand()
- [ ] Wrap `sendMediaCommand()` in retry loop (max 1 retry)
- [ ] On network error or timeout, wait 500ms and retry once
- [ ] Log retry attempts
- [ ] Throw error if both attempts fail
- [ ] **Validation**: Flaky network connections succeed on retry

## Phase 3: Output Switching (Seamless Transitions)

### 10. Add isSwitchingOutput guard to TermKitTranscoderUI
- [ ] Add `private var isSwitchingOutput = false` property
- [ ] Guard at start of `applyOutputChoice()` to prevent concurrent switches
- [ ] Set flag before switch, clear after
- [ ] Log message if switch blocked
- [ ] **Validation**: Second switch during first is ignored

### 11. Add visual feedback during output switching
- [ ] At start of `applyOutputChoice()`, set `statusLabel.text = "Status: switching output..."`
- [ ] On success, update to "Status: <output> set to <device>"
- [ ] On error, update to "Status: <output> error <message>"
- [ ] Ensure flag cleared in all paths (success, error, cancellation)
- [ ] **Validation**: Status updates visible during switch

### 12. Add position validation after output switch
- [ ] After launching new player, call `try? player.getPosition()`
- [ ] Compare to `lastKnownPosition`
- [ ] If difference > 2.0s, log warning: "Position drift after switch: expected Xs, got Ys"
- [ ] Don't throw or block switch (log only)
- [ ] **Validation**: Drift warnings appear in logs when expected

### 13. Preserve pause state across switches
- [ ] After launching new player, check `lastKnownPaused`
- [ ] If paused, call `try? player.pause()` on new player
- [ ] Verify pause state preserved in manual testing
- [ ] **Validation**: Switch while paused keeps new player paused

## Phase 4: Position Accuracy (Polish)

### 14. Add GET_STATUS request helper to CastV2Client
- [ ] Add `requestMediaStatus()` method
- [ ] Sends GET_STATUS command to media namespace
- [ ] Chromecast responds with fresh MEDIA_STATUS
- [ ] Update `latestMediaStatus` when response arrives
- [ ] **Validation**: Manual test shows position updates after call

### 15. Add active polling during Chromecast playback
- [ ] In `TermKitTranscoderUI.startTimer()`, detect if player is ChromecastPlayer
- [ ] If playing (not paused), call `requestMediaStatus()` every 1s
- [ ] Skip polling when paused or using mpv
- [ ] **Validation**: Position updates smoothly during playback

### 16. Add position interpolation to ChromecastPlayer
- [ ] Track `statusTimestamp: Date` when `latestMediaStatus` is updated
- [ ] In `getPosition()`, if playerState == .playing, calculate `elapsed = Date() - statusTimestamp`
- [ ] Return `status.currentTime + elapsed`
- [ ] If paused, return `status.currentTime` (no interpolation)
- [ ] Clamp to duration: `min(interpolated, duration)`
- [ ] **Validation**: Progress bar updates smoothly between MEDIA_STATUS updates

### 17. Add position drift detection
- [ ] In timer callback, compare `server.currentPosition` with `player.getPosition()`
- [ ] If difference > 3.0s, log warning: "Position drift: server Xs, player Ys (drift: Zs)"
- [ ] Skip detection if seek occurred within last 2s (`lastSeekTime`)
- [ ] Log only, don't auto-correct
- [ ] **Validation**: Drift warnings appear when positions diverge

## Phase 5: Integration Testing

### 18. Test rapid output switching
- [ ] Switch mpv → Chromecast → mpv → Chromecast 10 times rapidly
- [ ] Verify no crashes or hangs
- [ ] Verify position preserved within ±2s each switch
- [ ] Verify status labels update correctly
- [ ] **Validation**: All 10 switches succeed, position accurate

### 19. Test seek accuracy on Chromecast
- [ ] Play video on Chromecast for 30s
- [ ] Seek to 10s, verify arrival within ±1s
- [ ] Seek to 50s, verify arrival within ±1s
- [ ] Seek to 90s, verify arrival within ±1s
- [ ] Check logs for validation timeouts
- [ ] **Validation**: All seeks land within tolerance, no warnings

### 20. Test position tracking accuracy
- [ ] Play video on Chromecast for 60s
- [ ] Record displayed position every 5s
- [ ] Compare to actual Chromecast position (via phone app)
- [ ] Verify all readings within ±1s
- [ ] **Validation**: Position display accurate throughout

### 21. Test error scenarios
- [ ] Disconnect Chromecast mid-playback (unplug network)
- [ ] Verify error handling, logs, user feedback
- [ ] Reconnect and verify recovery
- [ ] Turn off Chromecast, try to connect
- [ ] Verify timeout, error message
- [ ] **Validation**: Errors handled gracefully, no crashes

### 22. Test concurrent operations
- [ ] Play video on Chromecast
- [ ] Rapidly press: seek, pause, play, seek, pause (within 2 seconds)
- [ ] Verify all commands execute in order
- [ ] Verify no race conditions or dropped commands
- [ ] Check logs for retries
- [ ] **Validation**: All commands execute, final state correct

## Dependencies

- **Parallel**: Tasks 1-2 can be done in parallel (different methods)
- **Sequential**: Task 3 depends on Task 2 (async pattern established)
- **Sequential**: Tasks 6-9 depend on Task 5 (thread safety verified)
- **Sequential**: Tasks 10-13 depend on Task 9 (reliable commands)
- **Sequential**: Tasks 14-17 depend on Task 13 (output switching stable)
- **Sequential**: Tasks 18-22 depend on all previous phases (integration testing)

## Out of Scope (Future Work)

- Unit tests for ChromecastPlayer (backlog)
- Automatic reconnection on disconnect (future feature)
- Volume control API (future feature)
- Subtitle/track selection (future feature)
- Playback rate control (future feature)

## Success Metrics

- **Thread Safety**: 100 rapid operations without crash
- **Responsiveness**: Seek responds in <200ms (vs current 1000ms)
- **Position Accuracy**: ±1s throughout playback
- **Switch Accuracy**: ±2s position preserved across switches
- **Reliability**: 100 operations without unhandled error
