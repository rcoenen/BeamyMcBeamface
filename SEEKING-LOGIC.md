# Seeking Logic in Beamy

## Overview

Beamy uses FFmpeg to transcode video files into HLS (HTTP Live Streaming) format for playback. The seeking behavior differs significantly between **embedded playback** (WebView with Safari's HLS player) and **external playback** (Chromecast or mpv).

## Architecture

```
Video File → FFmpeg TranscodeServer → HLS Stream → Player
                (real-time)           (segments)
```

### The Transcoding Pipeline

1. **Input**: Original video file (MP4, MKV, WEBM, MOV, AVI, etc.)
2. **FFmpeg Process**: Transcodes video in real-time to H.264 + AAC
3. **HLS Output**:
   - Playlist file (`stream.m3u8`)
   - Video segments (`segment00001.ts`, `segment00002.ts`, etc.)
   - Each segment = 2 seconds of video
4. **HTTP Server**: Serves playlist and segments over HTTP
5. **Player**: Loads HLS stream and plays segments

### HLS Configuration Modes

#### Embedded Mode (`embeddedMode: true`)
```bash
-hls_time 2                    # 2-second segments
-hls_list_size 0               # Keep ALL segments in playlist (no deletion)
-hls_playlist_type event       # EVENT playlist (seekable, keeps history)
-hls_flags append_list+program_date_time
```

**Purpose**: Allow Safari to seek from the beginning and play smoothly without chasing "live edge"

**Tradeoff**: Disk space grows as all segments are retained

#### Chromecast/Live Mode (`embeddedMode: false`)
```bash
-hls_time 2                    # 2-second segments
-hls_list_size 6               # Keep only last 6 segments (~12 seconds)
-hls_flags delete_segments+append_list+omit_endlist+program_date_time
```

**Purpose**: Sliding window for live streaming, minimal disk usage

**Tradeoff**: Can't seek backward beyond 12 seconds, old segments are deleted

## The Real-Time Transcoding Constraint

**Key limitation**: FFmpeg transcodes at approximately **1x real-time speed**.

```
If video plays for 5 minutes → FFmpeg has transcoded ~5 minutes of content
If video plays for 30 seconds → FFmpeg has transcoded ~30 seconds of content
```

Even with the `ultrafast` preset, you cannot transcode faster than the video's natural playback speed. This is a fundamental limitation of video encoding.

### What This Means for Seeking

**Scenario**: 60-minute video, played for 10 minutes

```
Available segments: 00:00 ━━━━━━━━━━ 10:00 ░░░░░░░░░░░░░░░░░░░░ 60:00
                    (transcoded)         (not yet transcoded)
```

**Seeking behavior**:
- Seek to 5:00 → ✅ Works perfectly (segment exists)
- Seek to 8:30 → ✅ Works perfectly (segment exists)
- Seek to 10:15 → ❌ Jumps to ~10:00 (furthest available segment)
- Seek to 30:00 → ❌ Jumps to ~10:00 (furthest available segment)

## Seeking Implementation by Player Type

### 1. Embedded WebView Player (Safari HLS)

**Current Implementation**:
```swift
func seek(to time: TimeInterval) {
    hlsWebPlayerCoordinator?.seek(to: clamped)
    embeddedCurrentTime = clamped
}
```

**What happens**:
1. JavaScript sets `video.currentTime = targetTime`
2. Safari requests segment at that time from HLS playlist
3. If segment exists → seeks successfully
4. If segment doesn't exist → seeks to nearest available segment

**Limitation**: Can only seek within transcoded segments.

**User Experience**:
- ✅ Smooth playback from start
- ✅ Skip forward/backward by 10s within transcoded range
- ✅ Scrubbing within transcoded range
- ❌ Cannot jump ahead to untranscoded parts

### 2. Chromecast Player

**Current Implementation**:
```swift
func seek(to time: TimeInterval) {
    // Restart transcoder at new position
    chromecastSeekOffset = clamped
    server.seek(to: clamped, awaitClientReconnect: true)
    try chromecastPlayer.reload(url: server.url)
}
```

**What happens**:
1. Kill current FFmpeg process
2. Start new FFmpeg at `-ss {seekPosition}`
3. Wait for new segments to be generated
4. Reload Chromecast with new stream URL
5. Chromecast starts playing from new position

**Advantages**:
- ✅ Can seek to any position in the video
- ✅ Works with live stream limitations

**Tradeoffs**:
- Takes 2-5 seconds for seek to complete
- Brief interruption while stream restarts

### 3. External mpv Player

**Implementation**: Direct file playback
```swift
// mpv reads file directly, no transcoding
mpv --start={seekPosition} {videoFile}
```

**What happens**:
1. mpv opens file directly
2. Uses built-in decoders (no transcoding)
3. Seeks instantly using file index

**Advantages**:
- ✅ Instant seeking anywhere
- ✅ No transcoding overhead
- ✅ Full codec support

**Tradeoffs**:
- Opens separate window (not embedded)

## Why We Can't "Just Fix" Embedded Seeking

### Attempted Solution 1: Restart Transcoder on Seek

```swift
// Tried this - it broke playback
func seek(to time: TimeInterval) {
    server.seek(to: clamped, awaitClientReconnect: false)
    wait(1.seconds)
    hlsWebPlayerCoordinator?.load(url: url)
}
```

**Problems**:
- WebView doesn't gracefully handle mid-playback stream reload
- Causes `:4` errors (resource loading failures)
- Playback breaks and doesn't recover
- Much worse UX than simple limitation

### Attempted Solution 2: Pre-transcode Entire Video

```bash
# Transcode entire 60-minute video upfront
ffmpeg -i input.mkv -hls_playlist_type vod output.m3u8
```

**Problems**:
- User waits 60 minutes before playback starts
- Defeats purpose of streaming
- Massive disk usage for large files
- Not suitable for quick playback

### Attempted Solution 3: Faster Transcoding

```bash
# Already using fastest preset
-preset ultrafast
```

**Reality**:
- Already as fast as possible without quality loss
- `ultrafast` is the fastest H.264 preset
- Cannot transcode faster than 1x real-time without specialized hardware
- Hardware encoding (videotoolbox) has compatibility issues

## Technical Details: HLS Playlist Types

### EVENT Playlist (Embedded Mode)
```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXT-X-PLAYLIST-TYPE:EVENT
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2.002000,
segment00000.ts
#EXTINF:2.002000,
segment00001.ts
#EXTINF:2.002000,
segment00002.ts
...
(keeps growing, all segments retained)
```

**Characteristics**:
- No `EXT-X-ENDLIST` (still growing)
- But keeps all segments from start
- Safari can seek from beginning
- Player doesn't chase "live edge"

### LIVE Playlist (Chromecast Mode)
```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:96
#EXTINF:2.002000,
segment00096.ts
#EXTINF:2.002000,
segment00097.ts
#EXTINF:2.002000,
segment00098.ts
#EXTINF:2.002000,
segment00099.ts
#EXTINF:2.002000,
segment00100.ts
#EXTINF:2.002000,
segment00101.ts
(sliding window, old segments deleted)
```

**Characteristics**:
- No `EXT-X-ENDLIST` (still growing)
- Only last 6 segments in playlist
- Old segments deleted from disk
- Safari chases "live edge" (problematic for playback)

## User Experience Tradeoffs

### Embedded Player (Current)

**Best for**:
- ✅ Watching from beginning
- ✅ Pause/resume
- ✅ Small skips (10s forward/backward)
- ✅ Scrubbing within transcoded range

**Not suitable for**:
- ❌ Jumping to arbitrary positions
- ❌ Previewing different parts of long video
- ❌ Random access to untranscoded sections

### External mpv

**Best for**:
- ✅ Full seeking control
- ✅ Instant seeking anywhere
- ✅ Previewing content

**Not suitable for**:
- ❌ Embedded in-window playback
- ❌ Unified UI experience

### Chromecast

**Best for**:
- ✅ TV playback
- ✅ Remote viewing
- ✅ Arbitrary seeking (with delay)

**Not suitable for**:
- ❌ Instant seeking (2-5s delay)
- ❌ Desktop playback

## Future Improvements

### Possible Enhancements

1. **Hybrid Mode**: Start embedded, switch to mpv for seeking
   ```swift
   if seekDistance > transcoded_range {
       switchToExternalMpv(at: position)
   }
   ```

2. **Smart Pre-transcoding**: Transcode ahead during idle time
   ```swift
   if player.paused && idle_for > 5.seconds {
       transcode_ahead(60.seconds)
   }
   ```

3. **Segment Prefetch**: Keep segments around seek target
   ```swift
   if user_scrubbing {
       keep_segments(current - 30s, current + 30s)
   }
   ```

4. **Progress Indicator**: Show transcoded range on seek bar
   ```swift
   ━━━━━━━━━━ (transcoded, seekable)
   ░░░░░░░░░░ (not transcoded, will jump back)
   ```

### Hardware Encoding Investigation

**Potential**: Use VideoToolbox for faster transcoding
```bash
-c:v h264_videotoolbox -b:v 8M
```

**Challenges**:
- Compatibility issues with some formats
- Quality vs speed tradeoffs
- Not available on all hardware
- Requires testing and fallback logic

## Conclusion

The current embedded seeking limitation is **not a bug** but a **fundamental constraint** of real-time HLS transcoding.

**The system works as designed**:
- FFmpeg transcodes at real-time speed
- HLS segments are created as transcoding progresses
- Safari can only seek within available segments
- Attempting workarounds breaks playback

**Recommended approach**:
- Use embedded player for normal playback from start
- Use external mpv when arbitrary seeking is needed
- Accept that embedded = limited seeking, external = full control

This is similar to how streaming services work: you can only seek within buffered content, not to arbitrary positions in unbuffered parts of the stream.
