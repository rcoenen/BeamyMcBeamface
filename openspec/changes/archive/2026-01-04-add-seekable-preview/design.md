# Design: Seekable Video Preview with Playback Controls

## Context

Users need full playback controls (play, pause, seek, progress display) for both local preview and Chromecast casting. Research shows that Plex, Jellyfin, and similar services solve this with on-demand transcoding and FFmpeg process control.

### Constraints
- macOS 13+
- FFmpeg/FFprobe required
- AVPlayer crashes on HTTP streams on macOS 26.1 beta (use file:// URL)
- Chromecast requires HTTP URL (can't access local files)

## Goals / Non-Goals

**Goals:**
- Seek bar with drag-to-position
- Play/Pause controls
- Time display (current / total / remaining)
- Works for local preview (instant)
- Works for Chromecast (1-2s seek latency acceptable)
- No pre-transcoding wait time

**Non-Goals:**
- Frame-accurate seeking (keyframe-accurate is fine)
- Multiple simultaneous streams
- Adaptive bitrate streaming

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GUI App                                  │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ Drop Zone   │  │ Video Player │  │ Playback Controls      │ │
│  │             │  │ (AVPlayer)   │  │ [◄◄] [▶/❚❚] [►►]       │ │
│  │  Drop file  │─▶│              │  │ ────●───────────────── │ │
│  │  here       │  │  file:// URL │  │ 01:23:45 / 02:15:00    │ │
│  └─────────────┘  └──────────────┘  └────────────────────────┘ │
│                           │                    │                │
│                           │ position/duration  │ seek/pause     │
│                           ▼                    ▼                │
│                   ┌──────────────────────────────┐              │
│                   │     CastingViewModel         │              │
│                   │  - currentTime: TimeInterval │              │
│                   │  - duration: TimeInterval    │              │
│                   │  - isPlaying: Bool           │              │
│                   └──────────────────────────────┘              │
│                              │                                  │
│              ┌───────────────┴───────────────┐                  │
│              ▼                               ▼                  │
│    ┌──────────────────┐           ┌──────────────────┐         │
│    │  Local Preview   │           │  Chromecast Cast │         │
│    │  (AVPlayer)      │           │  (TranscodeServer│         │
│    │                  │           │   + Caster)      │         │
│    │  file:// URL     │           │  http:// URL     │         │
│    │  Native seeking  │           │  FFmpeg control  │         │
│    └──────────────────┘           └──────────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

## Decisions

### Decision 1: Play original file for local preview

**What:** Local preview uses `file://` URL to play the original file directly.

**Why:**
- Instant playback, no transcoding delay
- Full native AVPlayer seeking
- Avoids AVPlayer HTTP crash on macOS 26.1 beta
- User can verify the source before casting

**Trade-off:** Preview shows original file, not transcoded output. But quality difference is minimal for typical H.264→H.264 transcoding.

### Decision 2: On-demand seeking for Chromecast via FFmpeg restart

**What:** When user seeks during Chromecast playback:
1. Kill current FFmpeg process
2. Start new FFmpeg with `-ss <time>` before `-i`
3. Chromecast reconnects to stream at new position

**Why:**
- Used by Plex/Jellyfin - proven approach
- FFmpeg's `-ss` before `-i` is fast (keyframe seeking)
- No pre-transcoding required
- 1-2 second latency acceptable for seeking

**FFmpeg command:**
```bash
ffmpeg -ss 01:23:45 -i input.mkv -c:v libx264 ... -f mp4 pipe:1
```

### Decision 3: SIGSTOP/SIGCONT for pause/resume

**What:** Pause transcoding by sending SIGSTOP to FFmpeg, resume with SIGCONT.

**Why:**
- Instant pause/resume
- FFmpeg handles this gracefully
- No stream restart needed
- Prevents buffer overflow during pause

**Implementation:**
```swift
func pause() {
    kill(ffmpegProcess.processIdentifier, SIGSTOP)
}

func resume() {
    kill(ffmpegProcess.processIdentifier, SIGCONT)
}
```

### Decision 4: Duration from MediaInfo, position from player

**What:**
- Total duration: From FFprobe via `MediaInfo.duration` (already implemented)
- Current position: From AVPlayer's `currentTime()` or Chromecast media status

**Why:**
- Duration is known before playback starts
- Position is real-time from the player
- Seek bar can be displayed immediately

**UI binding:**
```swift
@Published var duration: TimeInterval      // From MediaInfo
@Published var currentTime: TimeInterval   // From player observation
var progress: Double { currentTime / duration }
var timeRemaining: TimeInterval { duration - currentTime }
```

### Decision 5: Chromecast position tracking via Cast SDK

**What:** Get current playback position from Chromecast using `GCKRemoteMediaClient`.

**Why:**
- Chromecast reports position in media status updates
- Can poll or observe for updates
- Needed to show accurate seek bar during cast

**Note:** We're using the Cast V2 protocol directly, so we'll need to parse the MEDIA_STATUS messages for currentTime.

## Component Design

### TranscodeServer Enhancements

```swift
public final class TranscodeServer {
    // Existing
    private var ffmpegProcess: Process?

    // New: Playback control
    private var startPosition: TimeInterval = 0

    /// Seek to position - restarts FFmpeg
    public func seek(to time: TimeInterval) {
        stopFFmpeg()
        startPosition = time
        startFFmpeg(from: time)
    }

    /// Pause transcoding
    public func pause() {
        kill(ffmpegProcess!.processIdentifier, SIGSTOP)
    }

    /// Resume transcoding
    public func resume() {
        kill(ffmpegProcess!.processIdentifier, SIGCONT)
    }
}
```

### CastingViewModel State

```swift
@MainActor
class CastingViewModel: ObservableObject {
    // File info
    @Published var currentFile: URL?
    @Published var mediaInfo: MediaInfo?

    // Playback state
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    // Computed
    var progress: Double { duration > 0 ? currentTime / duration : 0 }
    var timeRemaining: TimeInterval { duration - currentTime }

    // Controls
    func play() { ... }
    func pause() { ... }
    func seek(to time: TimeInterval) { ... }
    func seek(to progress: Double) { seek(to: progress * duration) }
}
```

### Playback Controls View

```swift
struct PlaybackControlsView: View {
    @EnvironmentObject var viewModel: CastingViewModel

    var body: some View {
        VStack {
            // Seek bar
            Slider(value: $viewModel.progress, onEditingChanged: { editing in
                if !editing {
                    viewModel.seek(to: viewModel.progress)
                }
            })

            // Time display
            HStack {
                Text(formatTime(viewModel.currentTime))
                Spacer()
                Text("-\(formatTime(viewModel.timeRemaining))")
            }

            // Play/Pause
            Button(action: { viewModel.isPlaying ? viewModel.pause() : viewModel.play() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
        }
    }
}
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Seek latency (1-2s) | Acceptable for video; show loading indicator |
| AVPlayer crash on macOS 26.1 | Use file:// URL for local preview |
| FFmpeg doesn't restart cleanly | Kill with SIGKILL if SIGTERM fails |
| Chromecast loses connection on seek | Auto-reconnect, show "Reconnecting..." |
| Position drift during pause | Sync position on resume |

## Open Questions

1. Should we show transcoded preview option? (e.g., "Preview as Chromecast sees it")
   - Deferred: Start simple with original file preview

2. Buffer size for Chromecast streaming?
   - Use existing defaults, tune if needed

3. Seek while paused?
   - Yes, seek then remain paused
