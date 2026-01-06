# Proposal: Switch to Matroska Streaming

## Problem Statement

Chromecast Default Media Receiver rejects raw MPEG-TS streams sent over HTTP, causing playback to fail with `LOAD_FAILED` error despite successful connection and data transmission.

### Current Behavior
1. TranscodeServer streams raw MPEG-TS (`video/mp2t`) over HTTP
2. Chromecast connects and receives ~1.5MB of data
3. Chromecast sends `LOAD_FAILED` and closes connection
4. Blue Cast icon appears (receiver loaded) but no playback

### Root Cause
Raw MPEG-TS over HTTP is **not a supported Chromecast streaming protocol**. Google's [official documentation](https://developers.google.com/cast/docs/media) lists supported protocols as:
- HLS (m3u8 playlists)
- MPEG-DASH (MPD manifests)
- SmoothStreaming
- Progressive Download (MP4, WebM)

MPEG-TS is only supported as **HLS segments**, not raw HTTP streams.

### VLC Reference Implementation

Investigation of VLC's Chromecast implementation ([vlc/modules/stream_out/chromecast](https://github.com/videolan/vlc/tree/master/modules/stream_out/chromecast)) revealed:
- VLC successfully casts using **video/x-matroska** or **video/webm**
- Same Default Media Receiver app ID (`CC1AD845`)
- Same codecs (H.264 + AAC/MP3)
- Simple HTTP streaming (no HLS complexity)

This proves Chromecast accepts undocumented formats beyond official specs.

## Proposed Solution

**Replace MPEG-TS with Matroska container format** following VLC's proven approach:

### Changes Required
1. **FFmpeg output format**: `mpegts` → `matroska`
2. **HTTP Content-Type**: `video/mp2t` → `video/x-matroska`
3. **Chromecast loadMedia**: `"video/mp2t"` → `"video/x-matroska"`
4. **Remove MPEG-TS specific flags**: `-mpegts_flags +resend_headers`

### Why This Works
- ✅ VLC proves Default Media Receiver accepts Matroska
- ✅ Same H.264/AAC encoding (no transcoding changes)
- ✅ Both mpv and Chromecast support Matroska
- ✅ Simpler than implementing HLS
- ✅ No architectural changes needed

## Benefits

1. **Chromecast Compatibility**: Fixes LOAD_FAILED error, enables playback
2. **Simplicity**: Container swap vs. HLS implementation
3. **Universal Player Support**: Both mpv and Chromecast handle Matroska
4. **Proven Approach**: Follows VLC's battle-tested implementation
5. **No Quality Loss**: Same codecs, same quality settings

## Risks & Mitigations

**Risk**: Matroska may behave differently than MPEG-TS for seeking
- **Mitigation**: Test seeking thoroughly with both mpv and Chromecast
- **Fallback**: Minimal change, easy to revert if issues arise

**Risk**: Undocumented format could break with Chromecast updates
- **Mitigation**: VLC's long-term success suggests stability
- **Fallback**: Can implement HLS later if needed

## Alternatives Considered

### Option 1: Implement HLS
- **Pros**: Official Google-supported protocol
- **Cons**: Complex (segments, m3u8 manifests, cleanup), unnecessary overhead
- **Verdict**: Overengineering when Matroska works

### Option 2: MP4 Progressive Download
- **Pros**: Official support
- **Cons**: No live streaming, poor seeking, requires full transcode
- **Verdict**: Incompatible with on-the-fly transcoding

### Option 3: Keep MPEG-TS, add custom receiver
- **Pros**: No container change
- **Cons**: Requires hosting custom Chromecast receiver app, complex deployment
- **Verdict**: Excessive complexity

## Success Criteria

1. ✅ Chromecast playback starts successfully
2. ✅ No LOAD_FAILED errors
3. ✅ Seeking works on Chromecast (±2s accuracy)
4. ✅ mpv playback still works (backward compatibility)
5. ✅ Position tracking remains accurate

## Out of Scope

- HLS implementation (future if Matroska proves insufficient)
- Multiple quality levels / adaptive bitrate
- Custom Chromecast receiver app
- WebM container support (Matroska sufficient for now)

## References

- [Google Cast Supported Media](https://developers.google.com/cast/docs/media)
- [VLC Chromecast Implementation](https://github.com/videolan/vlc/tree/master/modules/stream_out/chromecast)
- [docs/CHROMECAST_STREAMING.md](../../../docs/CHROMECAST_STREAMING.md) - Technical findings
