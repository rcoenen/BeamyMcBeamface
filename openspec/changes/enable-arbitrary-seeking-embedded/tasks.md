# Tasks: Enable Arbitrary Seeking in Embedded Player

## Phase 1: Core Arbitrary Seek Implementation

### 1.1 Add cache-bust URL generation
- [ ] Add `cacheBustURL(_:)` method to CastingViewModel
- [ ] Generate unique URL with timestamp query parameter (e.g., `?t=1736188567.123`)
- [ ] Verify: Method produces unique URLs on each call
- [ ] Verify: URLComponents correctly appends query parameter

### 1.2 Implement arbitrary vs local seek detection
- [ ] Add logic to detect if seek is beyond currently-transcoded range
- [ ] Use `transcodeServer?.currentPosition` to determine transcoded boundary
- [ ] Add 2-second buffer to prevent unnecessary restarts for near-boundary seeks
- [ ] Verify: Seeks within transcoded range don't trigger FFmpeg restart
- [ ] Verify: Seeks beyond transcoded range trigger FFmpeg restart

### 1.3 Wire arbitrary seek flow into CastingViewModel
- [ ] Modify `seek(to:)` method to branch on arbitrary vs local seek
- [ ] Call `performArbitrarySeek(to:)` for beyond-range seeks
- [ ] Call `performLocalSeek(to:)` for within-range seeks
- [ ] Verify: Method routing works correctly based on seek position

### 1.4 Implement performArbitrarySeek method
- [ ] Create `performArbitrarySeek(to:)` method
- [ ] Set status message to "Seeking..."
- [ ] Call `transcodeServer.seek(to:awaitClientReconnect:false)`
- [ ] Generate cache-busted URL
- [ ] Call `hlsWebPlayerCoordinator?.load(url:cacheBustedURL)`
- [ ] Verify: FFmpeg restarts at correct position
- [ ] Verify: WebView reloads with cache-busted URL

### 1.5 Implement performLocalSeek method
- [ ] Create `performLocalSeek(to:)` method (or extract existing logic)
- [ ] Call `hlsWebPlayerCoordinator?.seek(to:)` for instant JavaScript seek
- [ ] Update `embeddedCurrentTime` binding
- [ ] Verify: Instant seeks work without FFmpeg restart

## Phase 2: Status Feedback & Polish

### 2.1 Add seeking state tracking
- [ ] Add `@Published private(set) var isArbitrarySeeking: Bool = false`
- [ ] Set `isArbitrarySeeking = true` when starting arbitrary seek
- [ ] Set `isArbitrarySeeking = false` when playback resumes
- [ ] Verify: State accurately reflects seek-in-progress

### 2.2 Update status messages
- [ ] Set statusMessage to "Seeking..." at start of arbitrary seek
- [ ] StatusMessage already updates to "Playing" via `onPlaybackStarted` callback
- [ ] Verify: User sees "Seeking..." then "Playing" sequence
- [ ] Verify: Status message doesn't show "Seeking..." for local seeks

### 2.3 Optional: Visual seeking indicator
- [ ] Consider adding ProgressView in PlaybackControlsView when `isArbitrarySeeking`
- [ ] Show spinner + "Seeking..." text overlay
- [ ] Verify: Visual feedback appears during arbitrary seek
- [ ] Verify: Indicator disappears when playback resumes

## Phase 3: Error Handling & Edge Cases

### 3.1 Handle stream poll timeout
- [ ] Verify `pollAndLoad()` already times out after 30 seconds
- [ ] Add error handling in Coordinator for timeout case
- [ ] Set `viewModel.errorMessage` and `statusMessage` on timeout
- [ ] Verify: User sees clear error message if stream doesn't come up
- [ ] Verify: User can retry seek after timeout

### 3.2 Handle FFmpeg restart failure
- [ ] Wrap `server.seek()` call in error handling
- [ ] Set appropriate error message if restart fails
- [ ] Verify: User sees error message if FFmpeg fails to start
- [ ] Verify: App doesn't crash on FFmpeg failure

### 3.3 Handle seek during seek
- [ ] Test: User seeks while previous arbitrary seek still in progress
- [ ] Verify: Previous seek is cancelled and new seek takes over
- [ ] OR: Verify: Second seek is queued until first completes
- [ ] Document chosen behavior in SEEKING-LOGIC.md

### 3.4 Handle seek during pause
- [ ] Test seeking to arbitrary position while video is paused
- [ ] Verify: Seek completes successfully
- [ ] Verify: Video remains paused at new position
- [ ] Verify: User can resume playback from new position

### 3.5 Handle rapid seek bar dragging
- [ ] Test rapid dragging of seek bar (multiple position changes)
- [ ] Verify: Current implementation already debounces via `onEnded` gesture
- [ ] Verify: Only final drag position triggers seek
- [ ] No additional debouncing needed (gesture handles this)

## Phase 4: Testing & Validation

### 4.1 Unit tests for seek detection
- [ ] Test `isArbitrarySeek` logic with various positions
- [ ] Test cache-bust URL generation
- [ ] Test seek method routing (arbitrary vs local)
- [ ] Verify: All edge cases covered

### 4.2 Integration tests
- [ ] Test: Seek from 5:00 to 30:00 in 60-minute video
- [ ] Test: Seek from 30:00 back to 5:00
- [ ] Test: Seek to beginning (0:00)
- [ ] Test: Seek to end (duration)
- [ ] Test: Multiple seeks in succession
- [ ] Test: Seek during pause
- [ ] Test: Seek during play
- [ ] Verify: All scenarios work without errors

### 4.3 Manual testing
- [ ] Test with short video (5 minutes)
- [ ] Test with medium video (30 minutes)
- [ ] Test with long video (2+ hours)
- [ ] Test seeking near beginning, middle, end
- [ ] Test output switching during arbitrary seek
- [ ] Monitor debug logs for cache-busted URLs
- [ ] Verify: No `:4` errors appear
- [ ] Verify: Seek latency is 2-5 seconds as expected

## Phase 5: Documentation Updates

### 5.1 Update SEEKING-LOGIC.md
- [ ] Add section: "Arbitrary Seeking in Embedded Player (Post-Implementation)"
- [ ] Document cache-busting approach
- [ ] Document 2-5 second seek latency as expected behavior
- [ ] Document seek detection logic (arbitrary vs local)
- [ ] Document that arbitrary seeks restart FFmpeg (same as Chromecast)
- [ ] Verify: Documentation matches implementation

### 5.2 Update code comments
- [ ] Add doc comments to `performArbitrarySeek()`
- [ ] Add doc comments to `performLocalSeek()`
- [ ] Add doc comments to `cacheBustURL()`
- [ ] Explain arbitrary vs local seek decision logic
- [ ] Verify: Code is well-documented for future maintenance

### 5.3 Update README or user docs (if applicable)
- [ ] Document that embedded player now supports arbitrary seeking
- [ ] Note that arbitrary seeks have 2-5s delay (expected)
- [ ] Explain difference from instant local seeks
- [ ] Verify: Users understand the behavior

## Dependencies

```
Phase 1 ──→ Phase 2 ──→ Phase 3 ──→ Phase 4 ──→ Phase 5
  (1.1)       (2.1)       (3.1)       (4.1)       (5.1)
    ↓           ↓           ↓           ↓           ↓
  (1.2)       (2.2)       (3.2)       (4.2)       (5.2)
    ↓           ↓           ↓           ↓           ↓
  (1.3)       (2.3)       (3.3)       (4.3)       (5.3)
    ↓                       ↓
  (1.4)                   (3.4)
    ↓                       ↓
  (1.5)                   (3.5)
```

- Phase 1 must complete before Phase 2 (core functionality first)
- Phase 2 can partially overlap Phase 3 (status feedback independent of error handling)
- Phase 4 depends on Phases 1-3 (need working implementation to test)
- Phase 5 depends on Phase 4 (document final behavior after testing)

## Validation Criteria

- [ ] ✅ Seek from 5:00 to 30:00 completes successfully in embedded mode
- [ ] ✅ Seek from 30:00 to 5:00 completes successfully
- [ ] ✅ Seek to arbitrary position completes within 2-5 seconds
- [ ] ✅ Status message shows "Seeking..." during arbitrary seek
- [ ] ✅ Status message shows "Playing" after seek completes
- [ ] ✅ No `:4` errors or playback failures occur
- [ ] ✅ Cache-busted URLs visible in debug logs (e.g., `?t=1736188567.123`)
- [ ] ✅ Seeking within transcoded range remains instant (no FFmpeg restart)
- [ ] ✅ Seeking beyond transcoded range triggers FFmpeg restart
- [ ] ✅ Rapid seek bar dragging processes only final position
- [ ] ✅ Seeking during pause works correctly
- [ ] ✅ Stream poll timeout shows clear error message
- [ ] ✅ FFmpeg restart failure shows clear error message
- [ ] ✅ Embedded seeking behavior matches Chromecast (arbitrary position support)
- [ ] ✅ Documentation updated to reflect new behavior

## Rollback Plan

If cache-busted reload approach fails:

1. Revert CastingViewModel changes
2. Restore original seek implementation (local-only)
3. Keep SEEKING-LOGIC.md documenting the limitation
4. Consider alternative approaches:
   - Switch to external mpv for arbitrary seeks (already available)
   - Implement monotonic segment numbering with discontinuities (complex)
   - Pre-transcode larger chunks during idle time (partial solution)

## Success Metrics

- [ ] User can seek to any position in video from embedded player
- [ ] Seek latency is acceptable (2-5 seconds for arbitrary seeks)
- [ ] No crashes or errors during seek operations
- [ ] User feedback (status messages) is clear and helpful
- [ ] Implementation matches design specification
- [ ] All validation criteria met
