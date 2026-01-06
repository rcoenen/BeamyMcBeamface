# Chromecast Streaming Technical Findings

## Discovery Date
2026-01-06

## Problem Statement
Attempted to stream raw MPEG-TS over HTTP to Chromecast using Cast V2 Protocol with the following configuration:
```swift
try client.loadMedia(
    url: server.url,              // http://192.168.8.236:8080/stream.ts
    contentType: "video/mp2t",    // Raw MPEG-TS container
    isLive: true                   // Live stream mode
)
```

## Observed Behavior
1. ✅ Chromecast connects to HTTP server successfully
2. ✅ HTTP headers sent and received
3. ✅ ~1.5MB of MPEG-TS data transmitted to Chromecast
4. ❌ Chromecast sends `LOAD_FAILED` message and closes connection
5. ❌ Blue Cast icon shown on TV (receiver app loaded but media rejected)

## Root Cause
**Raw MPEG-TS over HTTP is not a supported Chromecast streaming protocol.**

### What Chromecast Actually Supports
Per [Google Cast Supported Media Documentation](https://developers.google.com/cast/docs/media):

**Supported Streaming Protocols:**
- ✅ **HLS (HTTP Live Streaming)** - m3u8 playlists + segmented .ts files
- ✅ **MPEG-DASH** - MPD manifests + segmented media
- ✅ **SmoothStreaming** - manifests + fragments
- ✅ **Progressive Download** - single complete media file (MP4, WebM)
- ❌ **Raw MPEG-TS over HTTP** - NOT LISTED

**Supported Containers:**
- MP4, WebM, MP2T (only as HLS segments, not raw streams)

## Why We Used Raw MPEG-TS
- FFmpeg transcoding MKV → MPEG-TS for live streaming use case
- Works perfectly with mpv (mpv can consume raw MPEG-TS over HTTP)
- Assumed `"video/mp2t"` + `isLive: true` would enable raw streaming
- Needed on-the-fly transcoding with seeking support

## Comparison: mpv vs Chromecast

| Feature | mpv | Chromecast |
|---------|-----|------------|
| Raw MPEG-TS over HTTP | ✅ Yes | ❌ No |
| HLS (m3u8 + segments) | ✅ Yes | ✅ Yes |
| MP4 Progressive | ✅ Yes | ✅ Yes |
| Direct FFmpeg pipe | ✅ Yes | ❌ No |

## Solutions

### Option 1: Implement HLS (Recommended for Seeking)
**Change TranscodeServer to generate HLS manifests and segments**

**Architecture:**
```
FFmpeg → Segment .ts files → HTTP Server serves:
                             - /stream.m3u8 (manifest)
                             - /segment_001.ts
                             - /segment_002.ts
                             - ...
```

**Pros:**
- Both mpv and Chromecast support HLS
- Proper seeking support
- Industry-standard adaptive streaming
- Can add multiple quality levels later

**Cons:**
- More complex implementation
- Need segment management and cleanup
- Latency of 1-2 segments (configurable)

**FFmpeg Command Changes:**
```bash
# Old: Raw MPEG-TS to pipe
-f mpegts pipe:1

# New: HLS with segments
-f hls \
-hls_time 2 \                    # 2-second segments
-hls_list_size 10 \               # Keep last 10 segments in playlist
-hls_flags delete_segments \      # Auto-cleanup old segments
-hls_segment_filename /path/segment_%03d.ts \
/path/stream.m3u8
```

**Load Media Changes:**
```swift
// Change URL to point to m3u8 manifest
try client.loadMedia(
    url: URL(string: "http://192.168.8.236:8080/stream.m3u8")!,
    contentType: "application/vnd.apple.mpegurl",  // HLS MIME type
    isLive: true
)
```

### Option 2: MP4 Progressive Download (Simpler, Limited Seeking)
**Change FFmpeg output to MP4 container**

**Pros:**
- Simpler than HLS
- Both mpv and Chromecast support MP4

**Cons:**
- Requires full transcode before playback starts (no streaming)
- OR use fragmented MP4 (fMP4) but seeking is clunky
- Not ideal for large files

**FFmpeg Command:**
```bash
-movflags +frag_keyframe+empty_moov+default_base_moof \
-f mp4 pipe:1
```

### Option 3: Dual-Mode TranscodeServer (Maximum Compatibility)
**Support both MPEG-TS and HLS output modes**

**Architecture:**
- `/stream.ts` → raw MPEG-TS for mpv
- `/stream.m3u8` → HLS for Chromecast

**Pros:**
- Best of both worlds
- mpv keeps fast raw stream
- Chromecast gets proper HLS

**Cons:**
- Most complex implementation
- Two FFmpeg processes or output modes

## Recommendation

**Go with Option 1: Implement HLS**

**Rationale:**
1. HLS is the proper streaming protocol for live transcoding
2. Works with both mpv and Chromecast (uniform solution)
3. Industry standard with well-understood behavior
4. Enables future features (adaptive bitrate, quality switching)
5. Proper seeking support
6. mpv handles HLS just as well as raw MPEG-TS

**Implementation Complexity: Medium**
- Modify TranscodeServer to generate segments
- Add m3u8 manifest generation
- Add segment cleanup logic
- Update ChromecastPlayer to use m3u8 URL
- MpvPlayer automatically handles HLS URLs

## References
- [Google Cast Supported Media](https://developers.google.com/cast/docs/media)
- [HLS Requirements (Akamai)](https://techdocs.akamai.com/msl/docs/hls-requirements)
- [HLS Stream M3U8 Guide (VideoSDK)](https://www.videosdk.live/developer-hub/hls/hls-stream-m3u8)
- [HTTP Live Streaming (Wikipedia)](https://en.wikipedia.org/wiki/HTTP_Live_Streaming)

## Test Results

### What Works
- ✅ mpv playback with raw MPEG-TS over HTTP
- ✅ Chromecast discovery and connection
- ✅ Cast V2 Protocol communication
- ✅ FFmpeg transcoding MKV → MPEG-TS

### What Doesn't Work
- ❌ Chromecast playback with raw MPEG-TS over HTTP
- ❌ Using `contentType: "video/mp2t"` with Chromecast

## Next Steps

1. **Decision Point:** Choose between Option 1 (HLS) or Option 2 (MP4)
2. **Implementation:** Modify TranscodeServer for chosen protocol
3. **Testing:** Verify both mpv and Chromecast playback
4. **Documentation:** Update README with streaming protocol details
