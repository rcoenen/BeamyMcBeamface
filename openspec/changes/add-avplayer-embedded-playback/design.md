# Design: AVPlayer Embedded Playback

## Overview
This design replaces the crashed mpv-based embedded player with Apple's AVPlayer/AVKit framework. The transcoder runs for each dropped file and emits a single stream URL that both the embedded AVPlayer and Chromecast consume; no external player fallback.

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

Update to use AVPlayer for embedded playback and keep `TranscodeServer` as the single source stream for both embedded and Chromecast:

```swift
@Published var avPlayer: AVPlayer?
@Published var useEmbeddedPlayer: Bool = true  // Re-enable

// Embedded playback: AVPlayer loads transcoder stream URL
// Chromecast: uses the same server URL
```

State flow:
- `currentFile` set → ensure TranscodeServer is running for the file
- Create AVPlayer pointed at server URL
- Play/pause → control AVPlayer directly
- Seek → use AVPlayer.seek(to:)
- Position → observe AVPlayer.currentTime
- Switch to Chromecast → seek server to current position (if needed), launch cast client with server URL

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

## Stream Format Handling

- Transcoder must emit an AVPlayer-compatible stream (e.g., HLS/fMP4) from a single URL endpoint.
- AVPlayer loads the transcoder URL directly; no format detection or external fallback.
- Chromecast loads the same URL (or variant) from TranscodeServer.

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
3. Ensure TranscodeServer is running and seek to captured position
4. Connect Chromecast to the stream URL
5. Optionally: keep AVPlayer paused for quick switch-back

When switching from Chromecast to AVPlayer (local):

1. Get current position from Chromecast
2. Stop Chromecast playback
3. Keep TranscodeServer running for embedded playback
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
