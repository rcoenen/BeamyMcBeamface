# Design: AVPlayer Embedded Playback

## Overview
This design replaces the crashed mpv-based embedded player with Apple's AVPlayer/AVKit framework. Local playback stays on the original file; when switching to Chromecast we start the existing FFmpeg `TranscodeServer` on-demand and hand the cast client the server URL.

## Component Design

### 1. AVPlayerView (New)

A SwiftUI view wrapping AVKit's VideoPlayer:

```swift
// Sources/BeamyApp/AVPlayerView.swift
import SwiftUI
import AVKit

struct AVPlayerView: View {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { setupPlayer() }
            .onDisappear { cleanup() }
            .onChange(of: url) { setupPlayer() }
            .onChange(of: isPlaying) { syncPlaybackState() }
    }
}
```

Key responsibilities:
- Create/manage AVPlayer instance
- Observe playback time via `addPeriodicTimeObserver`
- Sync play/pause state with bindings
- Handle seek requests
- Clean up on disappear

### 2. CastingViewModel Changes

Update to use AVPlayer for local playback and keep `TranscodeServer` for Chromecast:

```swift
@Published var avPlayer: AVPlayer?
@Published var useEmbeddedPlayer: Bool = true  // Re-enable

// Local playback: AVPlayer on original file
// Chromecast: start TranscodeServer on-demand, launch cast client with server.url
```

State flow:
- `currentFile` set → create AVPlayer with file URL if playable
- Play/pause → control AVPlayer directly
- Seek → use AVPlayer.seek(to:)
- Position → observe AVPlayer.currentTime
- Switch to Chromecast → start TranscodeServer (if not running), seek server to current position, launch cast client

### 3. ContentView Changes

Replace MpvPlayerView with AVPlayerView:

```swift
// In ContentView.swift
if viewModel.useEmbeddedPlayer && viewModel.outputType == .mpv {
    AVPlayerView(
        url: viewModel.currentFile,
        isPlaying: $viewModel.embeddedIsPlaying,
        currentTime: $viewModel.embeddedCurrentTime,
        duration: $viewModel.embeddedDuration
    )
}
```

## Format Handling

### Directly Supported by AVPlayer (typical)
- MP4 (.mp4, .m4v)
- QuickTime (.mov)
- MPEG-4 audio (.m4a)
- HLS streams (.m3u8)

### Not Supported (Fallback Required)
- Matroska (.mkv)
- WebM (.webm)
- AVI (.avi)

### Detection
- First, pre-filter by extension (fast path).
- Confirm with `AVURLAsset(url:).isPlayable` to catch codec/container issues.

### Fallback Strategy (external mpv)
```swift
if !AVPlayerView.canPlay(url: url) {
    // Fall back to external mpv with file URL (no transcoder needed)
    MpvPlayer.play(fileURL: url)
    showMessage("Playing in external window (format not supported)")
}
```

## State Synchronization

### Play/Pause Flow
```
User clicks Play/Pause
       ↓
CastingViewModel.togglePlayPause()
       ↓
if outputType == .mpv:
    avPlayer.play() / avPlayer.pause()
else:
    chromecastPlayer.play() / chromecastPlayer.pause()
       ↓
embeddedIsPlaying binding updates
       ↓
AVPlayerView syncs state
```

### Seek Flow
```
User drags seek bar
       ↓
CastingViewModel.seekTo(position)
       ↓
if outputType == .mpv:
    avPlayer.seek(to: CMTime)
else:
    chromecastPlayer.seek(to: position)
       ↓
embeddedCurrentTime binding updates
```

### Position Tracking Flow
```
AVPlayer plays
       ↓
timeObserver fires (every 0.25s)
       ↓
Update embeddedCurrentTime binding
       ↓
PlaybackControlsView updates seek bar
```

## Output Switching

When switching from AVPlayer (local) to Chromecast:

1. Capture current position from AVPlayer
2. Pause AVPlayer
3. Start TranscodeServer (if not running) and seek to captured position
4. Connect Chromecast to stream (Matroska) at that URL
5. Optionally: keep AVPlayer paused for quick switch-back

When switching from Chromecast to AVPlayer (local):

1. Get current position from Chromecast
2. Stop Chromecast playback
3. Stop/cleanup TranscodeServer if not needed
4. Seek AVPlayer to position
5. Resume AVPlayer playback

## Error Handling

| Error | Handling |
|-------|----------|
| Unsupported format | Show error, offer external mpv fallback |
| File not found | Show error message in UI |
| Playback failed | Log error, show user-friendly message |
| Seek failed | Retry once, then show error |

## Testing Considerations

### Unit Tests
- AVPlayer creation with valid URL
- Time observer callback frequency
- Binding synchronization

### Integration Tests
- Play MP4 file end-to-end
- Seek to various positions
- Output switching with position preservation
- Unsupported format fallback

### Manual Tests
- Window activation (no crash)
- Multiple videos in session
- Long playback stability
