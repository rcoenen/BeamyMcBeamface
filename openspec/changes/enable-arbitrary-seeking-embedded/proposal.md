# Proposal: Enable Arbitrary Seeking in Embedded Player

## Change ID
`enable-arbitrary-seeking-embedded`

## Summary
Enable arbitrary seeking (to any position in the video) in the embedded HLS WebView player by restarting FFmpeg at the new position and reloading the WebView with a cache-busted URL, mirroring the approach already used successfully for Chromecast.

## Background

### Current Behavior
The embedded player (HLSWebPlayerView with Safari's native HLS player) can only seek within already-transcoded segments. This is because:
- FFmpeg transcodes at ~1x real-time speed
- HLS segments are created progressively as transcoding happens
- Safari can only play segments that already exist on disk
- Seeking to untranscoded portions fails or jumps to the furthest available segment

See `SEEKING-LOGIC.md` for comprehensive technical explanation.

### Problem
Users cannot seek to arbitrary positions in embedded playback (e.g., jumping from 5 minutes to 30 minutes). This creates an inconsistent UX between:
- **Chromecast**: Arbitrary seeking works (restarts FFmpeg at new position)
- **Embedded player**: Limited to already-transcoded range only

### Current Workaround
As documented in SEEKING-LOGIC.md, an attempted solution (restart transcoder + reload WebView) was tried but abandoned because:
- Safari doesn't gracefully handle mid-playback stream reload with same URL
- Caused `:4` errors (resource loading failures)
- Implementation was incomplete - never added proper cache-busting or "wait until ready" gate

## Solution

Implement the **same approach Chromecast uses**, but adapted for WebView:

1. **Detect arbitrary seek**: User seeks beyond currently-transcoded range
2. **Restart FFmpeg**: Kill current process, start new one with `-ss <target_time>`
3. **Wait for stream ready**: Poll new HLS playlist until it's available (already implemented in `pollAndLoad()`)
4. **Reload WebView with cache-busted URL**: Add timestamp or random parameter to URL to force Safari to treat it as a new stream
5. **Resume playback**: WebView starts playing from new position

### Key Technical Details

**Cache-busting URL pattern:**
```swift
// Old (failed) approach: same URL
http://192.168.1.100:8080/stream.m3u8

// New approach: cache-busted URL
http://192.168.1.100:8080/stream.m3u8?t=1736188567.123
```

**Transcoder restart with wait gate:**
```swift
func seek(to time: TimeInterval) {
    // For embedded: restart transcoder, then reload WebView
    if useEmbeddedPlayer && outputType == .mpv {
        server.seek(to: clamped, awaitClientReconnect: false)
        let cacheBustedURL = server.url.appendingQueryParameter("t", Date().timeIntervalSince1970)
        hlsWebPlayerCoordinator?.load(url: cacheBustedURL)  // Triggers pollAndLoad
    }
    // For Chromecast: existing behavior
    else if outputType == .chromecast {
        server.seek(to: clamped, awaitClientReconnect: true)
        try chromecastPlayer.reload(url: server.url)
    }
}
```

**Already implemented foundation:**
- `TranscodeServer.seek(to:)` - restarts FFmpeg at new position ✅
- `HLSWebPlayerView.pollAndLoad()` - waits for stream ready before loading ✅
- `HLSWebPlayerView.load()` - loads new URL into WebView ✅

**Missing piece:**
- Cache-busting URL parameter to force Safari to treat reloaded stream as fresh

## Scope

### In Scope
1. **Arbitrary seeking in embedded player** - Jump to any position in video, even untranscoded
2. **Cache-busted URL reloading** - Force Safari to reload stream as new resource
3. **Wait-until-ready gate** - Don't reload WebView until new HLS playlist exists (already implemented)
4. **Unified seeking behavior** - Same UX for embedded and Chromecast (both support arbitrary seeks)
5. **Status feedback** - Show "Seeking..." during FFmpeg restart

### Out of Scope
- Instant seeking (inherent 2-5 second delay while FFmpeg restarts and generates first segments)
- Pre-transcoding entire file (defeats purpose of real-time streaming)
- Keeping old segments (increases disk usage, complicates playlist management)
- Changing HLS format or playlist structure

## Design Rationale

### Why This Approach Will Work (Unlike Previous Attempt)

**Previous attempt failed because:**
- Used same URL → Safari cached playlist/segments, got confused
- No wait gate → tried to load before new segments existed
- Incomplete implementation → abandoned when it broke

**This approach will succeed because:**
- Cache-busted URL → Safari treats it as new stream, no confusion
- Wait gate already exists → `pollAndLoad()` waits for stream ready
- Chromecast proves pattern works → same FFmpeg restart flow, just different client reload
- Clear user feedback → "Seeking..." status during restart

### Alternative Approaches Considered

**1. Keep monotonic segment numbering across restarts**
- Requires significant TranscodeServer changes
- Must maintain segment continuity and use `EXT-X-DISCONTINUITY` tags
- More complex than cache-busting approach
- Rejected: Too complex for minimal benefit

**2. Dynamic segment generation on-demand**
- Intercept Safari's segment requests and generate/modify on-the-fly
- Requires TS container timestamp rewriting (CPU intensive)
- Extremely fragile and error-prone
- Rejected: Way too complex

**3. Switch to external mpv for arbitrary seeks**
- Already available as workaround
- Breaks embedded playback experience
- User loses in-window playback
- Rejected: Defeats purpose of embedded player

## Capabilities Affected

### Modified Capability: `video-preview`
Add requirement for arbitrary seeking in embedded player with FFmpeg restart approach.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Safari doesn't reload cleanly | High | Use cache-busted URL parameter to force fresh stream treatment |
| Delay during seek (2-5s) | Medium | Show clear "Seeking..." status, document this is expected behavior |
| User seeks multiple times rapidly | Medium | Debounce seeks or cancel pending restarts, only process final position |
| FFmpeg restart fails | Low | Show error message, fall back to current position |
| Stream poll timeout | Low | Show error after 30s, allow retry |

## Success Criteria

1. ✅ User can seek from 5:00 to 30:00 in embedded player (video has not been transcoded to 30:00 yet)
2. ✅ Playback resumes at target position within 2-5 seconds
3. ✅ Status message shows "Seeking..." during FFmpeg restart
4. ✅ Multiple rapid seeks process final position only (no excessive restarts)
5. ✅ Seeking behavior matches Chromecast (arbitrary position support)
6. ✅ No `:4` errors or playback failures
7. ✅ Cache-busted URLs visible in debug logs
8. ✅ Existing limited seeking (within transcoded range) still works via `video.currentTime` for instant seeks

## Implementation Notes

### Seek Decision Logic
```swift
func seek(to time: TimeInterval) {
    // Determine if this is "arbitrary" (beyond transcoded) or "local" (within transcoded)
    let isArbitrarySeek = time > (transcodeServer?.currentPosition ?? 0)

    if useEmbeddedPlayer && outputType == .mpv {
        if isArbitrarySeek {
            // Restart FFmpeg approach (2-5s delay)
            restartTranscoderAndReload(at: time)
        } else {
            // Instant seek within already-transcoded segments
            hlsWebPlayerCoordinator?.seek(to: time)
        }
    }
}
```

### Status Feedback
```swift
func restartTranscoderAndReload(at time: TimeInterval) {
    statusMessage = "Seeking..."
    server.seek(to: time, awaitClientReconnect: false)
    let cacheBustedURL = server.url.appendingCacheBustParameter()
    hlsWebPlayerCoordinator?.load(url: cacheBustedURL)
    // Status will update to "Playing" when WebView fires 'playing' event
}
```
