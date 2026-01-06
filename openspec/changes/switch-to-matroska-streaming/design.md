# Design: Switch to Matroska Streaming

## Architectural Overview

This change replaces the container format used for HTTP streaming from MPEG-TS to Matroska (MKV), affecting three components:

```
┌─────────────────────┐
│  TranscodeServer    │
│                     │
│  FFmpeg Process     │
│  -f mpegts          │ ──┐
│  ↓                  │   │ REPLACE
│  -f matroska        │ ──┘
│                     │
│  HTTP Server        │
│  Content-Type:      │
│  video/mp2t         │ ──┐
│  ↓                  │   │ REPLACE
│  video/x-matroska   │ ──┘
└─────────────────────┘
         │
         │ HTTP Stream
         ↓
┌─────────────────────┐
│  Players            │
├─────────────────────┤
│  mpv                │ ✅ Supports both
│  Chromecast         │ ✅ Supports Matroska (not MPEG-TS)
└─────────────────────┘
```

## Component Changes

### 1. TranscodeServer (FFmpeg Output)

**File**: `Sources/BeamyKit/FFmpeg/TranscodeServer.swift`

**Current FFmpeg Arguments** (lines 247-256):
```swift
args += [
    "-force_key_frames", "expr:eq(n,0)",
    "-flush_packets", "1",
    "-fflags", "+flush_packets+genpts",
    "-mpegts_flags", "+resend_headers",  // ← REMOVE (MPEG-TS specific)
    "-f", "mpegts",                      // ← CHANGE to "matroska"
    "pipe:1"
]
```

**New FFmpeg Arguments**:
```swift
args += [
    "-force_key_frames", "expr:eq(n,0)",
    "-flush_packets", "1",
    "-fflags", "+flush_packets+genpts",
    "-f", "matroska",                    // ← CHANGED
    "pipe:1"
]
```

**Rationale**:
- Matroska muxer handles flush/keyframe settings natively
- `-mpegts_flags` is MPEG-TS specific, not needed for Matroska
- `+flush_packets+genpts` still needed for live streaming

### 2. TranscodeServer (HTTP Headers)

**File**: `Sources/BeamyKit/FFmpeg/TranscodeServer.swift`

**Current HTTP Response** (lines 143-152):
```swift
let headers = """
HTTP/1.1 200 OK\r
Content-Type: video/mp2t\r              // ← CHANGE
Access-Control-Allow-Origin: *\r
Cache-Control: no-cache\r
Connection: close\r
\r

"""
```

**New HTTP Response**:
```swift
let headers = """
HTTP/1.1 200 OK\r
Content-Type: video/x-matroska\r        // ← CHANGED
Access-Control-Allow-Origin: *\r
Cache-Control: no-cache\r
Connection: close\r
\r

"""
```

**Rationale**:
- `video/x-matroska` is the standard MIME type for Matroska containers
- VLC uses this exact MIME type successfully
- Matches Chromecast expectations

### 3. ChromecastPlayer (Media Loading)

**File**: `Sources/BeamyKit/Player/ChromecastPlayer.swift`

**Current loadMedia Call** (line 17):
```swift
try client.loadMedia(url: url, contentType: "video/mp2t", isLive: true)
```

**New loadMedia Call**:
```swift
try client.loadMedia(url: url, contentType: "video/x-matroska", isLive: true)
```

**Rationale**:
- Tells Chromecast to expect Matroska container
- Matches HTTP Content-Type header
- `isLive: true` still valid for streaming Matroska

## Container Format Comparison

| Feature | MPEG-TS | Matroska |
|---------|---------|----------|
| **Chromecast Support** | ❌ Raw HTTP (only HLS) | ✅ HTTP streaming |
| **mpv Support** | ✅ Yes | ✅ Yes |
| **Seeking** | Good (fixed intervals) | Excellent (cue points) |
| **Overhead** | ~3% (188-byte packets) | ~1% (EBML headers) |
| **Live Streaming** | Designed for it | Supported via FFmpeg |
| **VLC Uses** | No | ✅ Yes |

## Behavioral Implications

### FFmpeg Muxing
- Matroska muxer automatically creates **seekable cue points** at keyframes
- Better random access than MPEG-TS (which uses fixed packet intervals)
- Slightly lower overhead (EBML vs 188-byte TS packets)

### HTTP Streaming
- Same chunked transfer over persistent connection
- No changes to HTTP server logic
- Same socket write patterns

### Player Behavior
- **mpv**: Handles Matroska identically to MPEG-TS (native support)
- **Chromecast**: Accepts Matroska, rejects raw MPEG-TS

### Seeking Performance
- **Matroska advantage**: Explicit cue points at keyframes
- **MPEG-TS advantage**: None (requires scanning for sync bytes)
- **Net result**: Equal or better seeking with Matroska

## Backward Compatibility

### Breaking Changes
- None - both mpv and Chromecast support Matroska

### Migration Path
- Single atomic change (all 3 components updated together)
- No config file changes
- No user-facing changes (transparent swap)

## Error Handling

### FFmpeg Errors
- Matroska muxer may fail if codecs incompatible
  - **Current**: H.264 + AAC (both Matroska-compatible)
  - **No new failures expected**

### Chromecast Errors
- If Matroska rejected: Same `LOAD_FAILED` as current MPEG-TS
  - **Unlikely**: VLC proves stability
  - **Fallback**: Revert 3-line change

## Performance Considerations

### CPU Impact
- Matroska muxing: Negligible overhead (metadata writes)
- Same encoding (H.264/AAC), same CPU usage

### Memory Impact
- Matroska maintains internal cue index
- Overhead: ~100KB for 1-hour video (negligible)

### Network Impact
- Slightly lower overhead (1% vs 3%)
- Better compression of stream metadata

## Testing Strategy

### Unit Testing
- Not applicable (container format swap, no logic changes)

### Integration Testing
1. **mpv Playback**: Verify existing functionality
   - Play, pause, seek, position tracking
2. **Chromecast Playback**: New capability
   - Connection, loading, playback start
   - Seek accuracy (±2s tolerance)
3. **Switching**: mpv ↔ Chromecast
   - Position preserved across switches
   - No crashes or hangs

### Validation Criteria
- ✅ mpv plays Matroska stream (existing)
- ✅ Chromecast plays Matroska stream (new)
- ✅ No LOAD_FAILED errors
- ✅ Seeking works on both players
- ✅ Position tracking accurate (±1s)

## Rollback Plan

If Matroska proves problematic:

1. **Immediate Rollback** (3-file revert):
   - TranscodeServer.swift: `matroska` → `mpegts`, add back `-mpegts_flags`
   - TranscodeServer.swift: `video/x-matroska` → `video/mp2t`
   - ChromecastPlayer.swift: `video/x-matroska` → `video/mp2t`

2. **Alternative Path**: Implement HLS
   - See [docs/CHROMECAST_STREAMING.md](../../../docs/CHROMECAST_STREAMING.md) Option 1

## Future Considerations

### HLS Implementation
- If Matroska causes unforeseen issues
- If adaptive bitrate needed later
- See proposal template in CHROMECAST_STREAMING.md

### WebM Support
- Chromecast also supports `video/webm`
- Could offer as alternative container
- Requires VP8/VP9 encoding (larger change)

### Quality Levels
- Matroska supports multiple tracks
- Could add quality switching without HLS
- Future optimization opportunity

## References

- [Matroska Specification](https://www.matroska.org/technical/specs/index.html)
- [FFmpeg Matroska Muxer](https://ffmpeg.org/ffmpeg-formats.html#matroska)
- [VLC Chromecast Code](https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/cast.cpp)
