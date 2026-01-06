# Tasks: Switch to Matroska Streaming

## Phase 1: Container Format Swap

### 1. Update FFmpeg output format to Matroska
- [ ] Open `Sources/BeamyKit/FFmpeg/TranscodeServer.swift`
- [ ] Locate FFmpeg arguments construction (around line 254)
- [ ] Change `"-f", "mpegts"` to `"-f", "matroska"`
- [ ] Remove `"-mpegts_flags", "+resend_headers"` line (MPEG-TS specific)
- [ ] **Validation**: Code compiles without errors

### 2. Update HTTP Content-Type header to Matroska
- [ ] Open `Sources/BeamyKit/FFmpeg/TranscodeServer.swift`
- [ ] Locate HTTP headers construction (around line 146)
- [ ] Change `Content-Type: video/mp2t` to `Content-Type: video/x-matroska`
- [ ] **Validation**: Header string formatted correctly (CRLF preserved)

### 3. Update ChromecastPlayer loadMedia content type
- [ ] Open `Sources/BeamyKit/Player/ChromecastPlayer.swift`
- [ ] Locate `loadMedia()` call in `reloadHandler` (around line 17)
- [ ] Change `contentType: "video/mp2t"` to `contentType: "video/x-matroska"`
- [ ] **Validation**: No other references to `"video/mp2t"` in codebase

### 4. Build and verify compilation
- [ ] Run `swift build`
- [ ] Ensure no compilation errors
- [ ] Ensure no warnings introduced
- [ ] **Validation**: Build succeeds with 0 errors

## Phase 2: Basic Functionality Testing

### 5. Test mpv playback with Matroska (backward compatibility)
- [ ] Start TUI: `swift run beamy transcode-test <video-file>`
- [ ] Select mpv output
- [ ] Press `p` to play
- [ ] Verify video plays smoothly
- [ ] Verify audio plays correctly
- [ ] **Validation**: mpv playback works identically to MPEG-TS

### 6. Test mpv seeking with Matroska
- [ ] With mpv playing, press `→` to seek forward
- [ ] Verify seek completes within 1-2 seconds
- [ ] Press `←` to seek backward
- [ ] Verify playback resumes at correct position
- [ ] **Validation**: Seeking accuracy within ±1s

### 7. Test Chromecast connection and loading
- [ ] In TUI, switch output to Chromecast
- [ ] Select Chromecast device from discovery
- [ ] Observe Chromecast logs: `tail -f /tmp/beamy-cast.log`
- [ ] Verify no `LOAD_FAILED` error in logs
- [ ] Verify `MEDIA_STATUS` with `playerState: "PLAYING"` or `"BUFFERING"`
- [ ] **Validation**: No LOAD_FAILED, media loads successfully

### 8. Test Chromecast playback start
- [ ] After loading, observe Chromecast TV screen
- [ ] Verify video displays (not blue Cast icon)
- [ ] Verify audio plays
- [ ] Verify position updates in TUI every 1s
- [ ] **Validation**: Chromecast playback starts and continues

## Phase 3: Advanced Functionality Testing

### 9. Test Chromecast pause/resume
- [ ] With Chromecast playing, press `p` to pause
- [ ] Verify TUI shows "Status: paused"
- [ ] Verify Chromecast shows paused frame
- [ ] Press `p` to resume
- [ ] Verify playback continues
- [ ] **Validation**: Pause/resume works on Chromecast

### 10. Test Chromecast seeking forward
- [ ] Note current position (e.g., 30s)
- [ ] Press `→` to seek forward
- [ ] Observe Chromecast logs for SEEK command
- [ ] Verify position updates to new time
- [ ] Verify video jumps to new position
- [ ] **Validation**: Seek lands within ±2s of target

### 11. Test Chromecast seeking backward
- [ ] Note current position (e.g., 60s)
- [ ] Press `←` to seek backward
- [ ] Verify position decreases
- [ ] Verify video jumps backward
- [ ] Verify playback continues from new position
- [ ] **Validation**: Backward seek works correctly

### 12. Test output switching mpv → Chromecast
- [ ] Start playback on mpv at 0s
- [ ] Let play for 10s
- [ ] Switch output to Chromecast
- [ ] Verify position preserved (10s ±2s on Chromecast)
- [ ] Verify playback continues on Chromecast
- [ ] **Validation**: Position drift < 2s, no crashes

### 13. Test output switching Chromecast → mpv
- [ ] Start playback on Chromecast at 0s
- [ ] Let play for 15s
- [ ] Switch output to mpv
- [ ] Verify position preserved (15s ±2s on mpv)
- [ ] Verify playback continues on mpv
- [ ] **Validation**: Position drift < 2s, no crashes

## Phase 4: Edge Cases & Stress Testing

### 14. Test rapid seeking on Chromecast
- [ ] Press `→` rapidly 5 times (within 2 seconds)
- [ ] Verify all seek commands process
- [ ] Verify final position is correct
- [ ] Check logs for any errors
- [ ] **Validation**: No crashes, commands queue properly

### 15. Test large seek jumps
- [ ] Seek from 0s to end of video (e.g., 3600s)
- [ ] Verify seek completes (may take 2-3s)
- [ ] Seek from end back to 0s
- [ ] Verify video restarts from beginning
- [ ] **Validation**: Large jumps work on both players

### 16. Test playback near video end
- [ ] Seek to last 10 seconds of video
- [ ] Let video play to completion
- [ ] Observe behavior when video ends
- [ ] Verify no crashes or errors
- [ ] **Validation**: Graceful handling of end-of-stream

### 17. Test position tracking accuracy
- [ ] Play video on Chromecast for 60 seconds
- [ ] Compare TUI position display with actual Chromecast position (use phone app)
- [ ] Record position every 10 seconds
- [ ] Calculate drift over time
- [ ] **Validation**: Position drift < 1s throughout playback

### 18. Test concurrent Chromecast status requests
- [ ] Play video on Chromecast
- [ ] Observe polling logs (GET_STATUS every 1s)
- [ ] Verify no request collisions or timeouts
- [ ] Check for smooth position updates in TUI
- [ ] **Validation**: Polling works without errors

## Phase 5: Error Scenarios

### 19. Test Chromecast disconnect during playback
- [ ] Start playback on Chromecast
- [ ] Unplug Chromecast network cable (or disable Wi-Fi)
- [ ] Observe error handling in TUI
- [ ] Verify logs show connection errors
- [ ] Reconnect Chromecast
- [ ] **Validation**: Errors logged, no crashes, graceful degradation

### 20. Test FFmpeg failure with Matroska
- [ ] Try playing a corrupted or unsupported video file
- [ ] Observe FFmpeg error messages
- [ ] Verify TUI shows meaningful error to user
- [ ] **Validation**: Errors handled gracefully, no crashes

### 21. Test HTTP server restart
- [ ] Kill beamy TUI process while Chromecast is playing
- [ ] Observe Chromecast behavior (should show error)
- [ ] Restart TUI with same video
- [ ] Reconnect Chromecast
- [ ] **Validation**: Can recover from server restart

## Phase 6: Performance & Regression Testing

### 22. Verify no new compiler warnings
- [ ] Run `swift build` fresh
- [ ] Count warnings before change (baseline)
- [ ] Count warnings after change
- [ ] Ensure count did not increase
- [ ] **Validation**: No new warnings introduced

### 23. Compare CPU usage MPEG-TS vs Matroska
- [ ] Start playback with Matroska, run `top` or Activity Monitor
- [ ] Record CPU % for FFmpeg process
- [ ] Compare to documented MPEG-TS baseline (if available)
- [ ] Verify CPU usage is comparable (±5%)
- [ ] **Validation**: No significant CPU regression

### 24. Compare memory usage
- [ ] Monitor beamy process memory during playback
- [ ] Record peak memory usage
- [ ] Compare to MPEG-TS baseline (if available)
- [ ] Verify memory usage is comparable
- [ ] **Validation**: No significant memory increase

### 25. Verify no log spam
- [ ] Play video for 5 minutes
- [ ] Review `/tmp/beamy-tui.log`
- [ ] Review `/tmp/beamy-cast.log`
- [ ] Review `/tmp/beamy-transcoder-debug.log`
- [ ] Ensure no excessive repeated messages
- [ ] **Validation**: Logs are clean, informative, not spammy

## Dependencies

- **Sequential**: Tasks 1-4 must complete before testing (Phase 1 → Phase 2)
- **Parallel**: Tasks 5-6 (mpv tests) can run in parallel with tasks 7-8 (Chromecast tests)
- **Sequential**: Phase 2 must complete before Phase 3 (basic before advanced)
- **Parallel**: Tasks 9-13 (advanced features) can be tested in any order
- **Sequential**: Phases 4-5 require Phase 3 completion (edge cases after core features)

## Success Metrics

- ✅ **Compilation**: 0 errors, 0 new warnings
- ✅ **mpv Compatibility**: All existing functionality works
- ✅ **Chromecast Playback**: No LOAD_FAILED errors, playback starts
- ✅ **Seeking**: ±2s accuracy on Chromecast, ±1s on mpv
- ✅ **Output Switching**: Position preserved within ±2s
- ✅ **Position Tracking**: ±1s accuracy during playback
- ✅ **Stability**: No crashes in 25 test scenarios

## Out of Scope

- Unit tests (no existing test suite)
- Automated integration tests (manual testing sufficient)
- Performance benchmarking suite (manual comparison adequate)
- WebM container support (future enhancement)
- HLS implementation (only if Matroska fails)
