# Design: Arbitrary Seeking in Embedded Player

## Overview
Enable arbitrary seeking in the embedded HLS WebView player by restarting FFmpeg at the target position and reloading the WebView with a cache-busted URL. This mirrors the proven approach already used for Chromecast.

## Architecture

### Current Seeking Flow (Limited)

```
User drags seek bar to position within transcoded range
         ↓
CastingViewModel.seek(to: 15:00)
         ↓
hlsWebPlayerCoordinator?.seek(to: 15:00)
         ↓
WebView JS: video.currentTime = 900
         ↓
Safari seeks to segment covering 15:00 (instant)
```

**Works only if:** Segment at 15:00 exists on disk (already transcoded).

### New Seeking Flow (Arbitrary)

```
User drags seek bar to position beyond transcoded range
         ↓
CastingViewModel.seek(to: 30:00)
         ↓
Detect: 30:00 > transcodeServer.currentPosition (e.g., 10:00)
         ↓
Restart FFmpeg: kill old process, start with -ss 1800
         ↓
Wait for new stream ready: pollAndLoad() polls until stream.m3u8 exists
         ↓
Reload WebView with cache-busted URL: stream.m3u8?t=1736188567.123
         ↓
Safari loads fresh HLS stream starting at 30:00
         ↓
Playback resumes at target position (2-5s total delay)
```

**Key difference:** Cache-busted URL parameter forces Safari to treat this as a new stream, not a continuation of the old one.

## Component Changes

### 1. CastingViewModel

**New/Modified Methods:**

```swift
func seek(to time: TimeInterval) {
    let dur = useEmbeddedPlayer && outputType == .mpv ? effectiveDuration : duration
    let clamped = min(max(0, time), dur)

    if useEmbeddedPlayer && outputType == .mpv {
        // Determine if arbitrary seek needed
        let transcodedUpTo = transcodeServer?.currentPosition ?? 0
        let isArbitrarySeek = clamped > transcodedUpTo + 2.0  // 2s buffer

        if isArbitrarySeek {
            performArbitrarySeek(to: clamped)
        } else {
            performLocalSeek(to: clamped)
        }
    } else if outputType == .chromecast {
        // Existing Chromecast logic (already supports arbitrary seeks)
        performChromecastSeek(to: clamped)
    }
}

private func performArbitrarySeek(to time: TimeInterval) {
    guard let server = transcodeServer else { return }

    statusMessage = "Seeking..."

    // Restart FFmpeg at new position
    server.seek(to: time, awaitClientReconnect: false)

    // Generate cache-busted URL
    let cacheBustedURL = cacheBustURL(server.url)

    // Reload WebView with new URL (triggers pollAndLoad internally)
    hlsWebPlayerCoordinator?.load(url: cacheBustedURL)
}

private func performLocalSeek(to time: TimeInterval) {
    // Instant seek within already-transcoded segments
    hlsWebPlayerCoordinator?.seek(to: time)
    embeddedCurrentTime = time
}

private func cacheBustURL(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let timestamp = Date().timeIntervalSince1970
    components.queryItems = [URLQueryItem(name: "t", value: "\(timestamp)")]
    return components.url ?? url
}
```

**State Updates:**

```swift
// Status message already reactive
@Published var statusMessage: String = "Ready" {
    didSet {
        // Already logging status changes
    }
}

// Track if arbitrary seek in progress
@Published private(set) var isArbitrarySeeking: Bool = false
```

### 2. HLSWebPlayerView.Coordinator

**Already Has:**
- ✅ `pollAndLoad(url:)` - waits for stream ready before loading
- ✅ `load(url:)` - loads new URL into WebView
- ✅ `loadInWebView(url:)` - executes JavaScript `loadStream()`

**No changes needed!** Existing methods already support the new flow.

**Key behavior:**
```swift
func load(url: URL) {
    currentURL = url  // Update tracked URL
    if isReady {
        loadInWebView(url: url)
    } else {
        pendingURL = url
    }
}

func pollAndLoad(url: URL) {
    guard currentURL != url else { return }
    currentURL = url

    // Poll until stream is ready (up to 30 seconds)
    Task {
        var attempts = 0
        while attempts < 60 {
            // Check if stream.m3u8 exists and returns 200
            if headRequestSucceeds(url) {
                await MainActor.run {
                    if self.isReady {
                        self.loadInWebView(url: url)
                    } else {
                        self.pendingURL = url
                    }
                }
                return
            }
            attempts += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
```

### 3. TranscodeServer

**Already Has:**
- ✅ `seek(to:awaitClientReconnect:)` - restarts FFmpeg at position
- ✅ Clears HLS directory and starts fresh segment numbering

**No changes needed!** Existing implementation already supports the flow.

**Key behavior:**
```swift
public func seek(to time: TimeInterval, awaitClientReconnect: Bool) {
    // Kill old FFmpeg process
    if let process = ffmpegProcess, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        ffmpegProcess = nil
    }

    // Reset state
    currentSeekPosition = time
    currentPosition = time

    // Clear HLS directory
    try? FileManager.default.removeItem(at: hlsDirectory)
    try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)

    // Start new FFmpeg at -ss <time>
    startFFmpeg(at: time)
}
```

### 4. ContentView / PlaybackControlsView

**No UI changes needed!** Existing seek bar and controls work identically.

**Optional enhancement:** Show visual feedback during arbitrary seek
```swift
if viewModel.isArbitrarySeeking {
    HStack {
        ProgressView()
            .scaleEffect(0.7)
        Text("Seeking...")
            .font(.caption)
    }
}
```

## State Flow Diagram

### Arbitrary Seek State Machine

```
┌─────────────┐
│   Playing   │ (transcoded up to 10:00)
└──────┬──────┘
       │ User seeks to 30:00
       ▼
┌─────────────┐
│  Seeking    │ statusMessage = "Seeking..."
│             │ Kill FFmpeg
│             │ Start FFmpeg -ss 1800
└──────┬──────┘
       │ Wait for stream.m3u8
       ▼
┌─────────────┐
│  Waiting    │ pollAndLoad() checks HEAD /stream.m3u8?t=...
│  for        │ Retry every 500ms (max 30s)
│  Stream     │
└──────┬──────┘
       │ Stream returns 200 OK
       ▼
┌─────────────┐
│  Reloading  │ WebView JS: loadStream(cacheBustedURL)
│  WebView    │
└──────┬──────┘
       │ Video element fires 'loadeddata'
       ▼
┌─────────────┐
│  Playing    │ statusMessage = "Playing"
│             │ (now at 30:00)
└─────────────┘
```

## Cache-Busting Strategy

### Why Cache-Busting Is Critical

Without cache-busting, Safari experiences:
1. **Playlist confusion**: Safari has cached `stream.m3u8` with segment list 00096-00101
2. **Segment 404s**: New FFmpeg creates segments 00000-00005, Safari requests 00102 → 404
3. **Stalled playback**: Safari doesn't know stream restarted, waits for segments that will never exist

With cache-busting:
1. **Fresh URL**: `stream.m3u8?t=1736188567.123` is treated as new resource
2. **New playlist load**: Safari fetches fresh playlist with segments 00000-00005
3. **Clean playback**: Safari starts from segment 00000, no confusion

### Implementation Details

**URL Transformation:**
```swift
// Before: http://192.168.1.100:8080/stream.m3u8
// After:  http://192.168.1.100:8080/stream.m3u8?t=1736188567.123

func cacheBustURL(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let timestamp = Date().timeIntervalSince1970

    // Append timestamp as query parameter
    components.queryItems = [URLQueryItem(name: "t", value: "\(timestamp)")]

    return components.url ?? url
}
```

**Server Handling:**
```swift
// In TranscodeServer.handleRequest(socket:)
// Already strips query parameters when serving files:

var path = String(parts[1])
if path == "/" { path = "/stream.m3u8" }

let relativePath = path.drop(while: { $0 == "/" })
// Query parameters ignored, serves stream.m3u8 regardless of ?t= param ✅
```

## Seek Debouncing

**Problem:** User rapidly drags seek bar, triggering multiple FFmpeg restarts.

**Solution:** Debounce seeks to only process final position.

```swift
private var seekDebounceTask: Task<Void, Never>?

func seek(to time: TimeInterval) {
    // Cancel pending seek
    seekDebounceTask?.cancel()

    // Schedule new seek after brief delay
    seekDebounceTask = Task {
        try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
        guard !Task.isCancelled else { return }

        await MainActor.run {
            performActualSeek(to: time)
        }
    }
}

private func performActualSeek(to time: TimeInterval) {
    // Actual seek logic (arbitrary vs local decision)
    // ...
}
```

**Alternative:** Only trigger on drag end (already implemented in ContentView)
```swift
.gesture(
    DragGesture(minimumDistance: 0)
        .onChanged { value in
            // Just update visual preview
            isDragging = true
            dragProgress = ...
        }
        .onEnded { value in
            // Trigger actual seek only on release ✅
            viewModel.seekToProgress(progress)
            isDragging = false
        }
)
```

Current implementation already debounces via `onEnded`, so no additional debouncing needed.

## Error Handling

### Stream Poll Timeout

```swift
func pollAndLoad(url: URL) {
    Task {
        var attempts = 0
        while attempts < 60 {  // 30 seconds max
            if headRequestSucceeds(url) {
                loadInWebView(url: url)
                return
            }
            attempts += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Timeout after 30s
        debugLog("Stream poll timeout")
        await MainActor.run {
            viewModel.errorMessage = "Seek failed - stream not ready"
            viewModel.statusMessage = "Seek failed"
        }
    }
}
```

### FFmpeg Restart Failure

```swift
func performArbitrarySeek(to time: TimeInterval) {
    guard let server = transcodeServer else {
        errorMessage = "Transcoder not available"
        return
    }

    statusMessage = "Seeking..."

    do {
        server.seek(to: time, awaitClientReconnect: false)
        let cacheBustedURL = cacheBustURL(server.url)
        hlsWebPlayerCoordinator?.load(url: cacheBustedURL)
    } catch {
        errorMessage = "Seek failed: \(error.localizedDescription)"
        statusMessage = "Seek failed"
    }
}
```

### Playback Failure After Reload

```swift
// In HLSWebPlayerView JavaScript:
video.addEventListener('error', function(e) {
    const err = video.error ? (video.error.code + ': ' + video.error.message) : 'unknown';
    errorDiv.textContent = err;
    log('error: ' + err);

    // Notify Swift side
    window.webkit.messageHandlers.player.postMessage('error:' + err);
});

// In Coordinator.userContentController:
if body.hasPrefix("error:") {
    let error = String(body.dropFirst(6))
    await MainActor.run {
        viewModel.errorMessage = "Playback error: \(error)"
        viewModel.statusMessage = "Playback failed"
    }
}
```

## Testing Strategy

### Unit Tests
- ✅ Cache-bust URL generation produces unique URLs
- ✅ Arbitrary seek detection (beyond transcoded range)
- ✅ Local seek detection (within transcoded range)
- ✅ Seek debouncing prevents rapid restarts

### Integration Tests
- ✅ Seek from 5:00 to 30:00 in 60-minute video
- ✅ Multiple seeks in rapid succession (debouncing)
- ✅ Seek while paused
- ✅ Seek during active playback
- ✅ Stream poll timeout handling
- ✅ FFmpeg restart failure handling

### Manual Tests
- ✅ Seek to various positions (near, far, beginning, end)
- ✅ Rapid seek bar dragging
- ✅ Seek during pause vs play states
- ✅ Output switch during arbitrary seek
- ✅ Network interruption during seek
- ✅ Long video (2+ hours) seeking

## Performance Considerations

### Seek Latency Breakdown

**Target:** 2-5 seconds for arbitrary seek

| Phase | Duration | Notes |
|-------|----------|-------|
| Kill old FFmpeg | <100ms | SIGKILL immediate |
| Start new FFmpeg | ~500ms | Process spawn + initialization |
| First segment generation | ~2s | Transcode 2s of video at 1x speed |
| Stream poll detection | <500ms | HEAD request every 500ms |
| WebView reload | ~500ms | JS execution + first segment fetch |
| **Total** | **~3.5s** | Acceptable for arbitrary seek |

### Memory Impact

**Cache-busted URLs don't accumulate:**
- Each seek creates new URL with timestamp
- Old URL references garbage collected when WebView loads new URL
- No memory leak from URL accumulation ✅

**HLS directory cleanup:**
```swift
// TranscodeServer.seek() already clears directory
try? FileManager.default.removeItem(at: hlsDirectory)
try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)
```
Old segments deleted on each restart, no disk bloat ✅

## Rollout Plan

### Phase 1: Core Implementation
- Implement cache-bust URL generation
- Wire arbitrary seek detection into `CastingViewModel.seek()`
- Test with single video

### Phase 2: Polish
- Add "Seeking..." status feedback
- Handle edge cases (seek during seek, rapid seeks)
- Error handling and timeout recovery

### Phase 3: Documentation
- Update SEEKING-LOGIC.md with new behavior
- Document that arbitrary seeks have 2-5s delay (expected)
- Add troubleshooting section
