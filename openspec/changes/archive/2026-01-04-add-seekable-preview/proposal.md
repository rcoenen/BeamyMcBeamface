# Change: Add Seekable Video Preview with Playback Controls

## Why

The current TranscodeServer outputs a live stream that doesn't support seeking, pausing, or showing playback progress. Users need:

1. **Seek bar** - Jump to any position in the video
2. **Play/Pause** - Control playback
3. **Time display** - Current position, total duration, time remaining
4. **Works for both** - Local preview AND Chromecast casting

## What Changes

### Core Insight (from research)

Services like Plex, Jellyfin, and Emby solve this by:
- Getting duration from FFprobe **upfront** (we already do this)
- On **seek**: Kill FFmpeg, restart with `-ss <position>` flag
- On **pause**: Send `SIGSTOP` to FFmpeg process
- On **resume**: Send `SIGCONT` to FFmpeg process

The source file is seekable - we just need to restart FFmpeg at the right position.

### Implementation

**Local Preview:**
- Play the **original file** directly with AVPlayer
- Full native seeking (no transcoding needed for preview)
- Use `file://` URL to avoid AVPlayer crash on macOS 26.1 beta
- Shows exactly what's in the file with full controls

**Chromecast Casting:**
- TranscodeServer with **on-demand seeking**:
  - `seek(to: time)` → Kill FFmpeg, restart with `-ss <time>`
  - `pause()` → `kill -STOP <ffmpeg_pid>`
  - `resume()` → `kill -CONT <ffmpeg_pid>`
- Chromecast reconnects automatically when stream restarts

**UI Controls:**
- Duration from `MediaInfo` (FFprobe) - known before playback
- Current position from AVPlayer (`currentTime`) or Chromecast media status
- Seek bar: drag to position, triggers seek
- Play/Pause button
- Time display: `01:23:45 / 02:15:00` format
- Time remaining: `-00:51:15`

## Impact

- Affected: `TranscodeServer.swift`, `CastingViewModel.swift`, `ContentView.swift`
- New: Playback controls UI, seek/pause/resume logic
- No full pre-transcoding required - instant start, real-time controls

## Trade-offs

| Feature | How it works | Latency |
|---------|--------------|---------|
| Pause/Resume | SIGSTOP/SIGCONT to FFmpeg | Instant |
| Seek | Restart FFmpeg with `-ss` | 1-2 seconds |
| Duration | FFprobe (upfront) | Instant |
| Position | Player reports | Real-time |

## Key Research Findings

1. **FFmpeg `-ss` flag** (before `-i`) does fast keyframe seeking - nearly instant
2. **SIGSTOP/SIGCONT** works reliably to pause/resume FFmpeg
3. **Fragmented MP4** (`movflags frag_keyframe+empty_moov`) allows streaming without pre-transcoding
4. **Chromecast** handles stream reconnection on seek
5. **Plex/Jellyfin** use exactly this approach - proven in production
