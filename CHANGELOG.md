# Changelog

## v0.2.0

### New Features
- **Bundled FFmpeg**: FFmpeg is now included in the app bundle - no external installation required
- **Hardware-accelerated encoding**: Uses Apple VideoToolbox (H.264) and AudioToolbox (AAC) for fast, efficient transcoding

### Improvements
- Simplified settings UI - removed FFmpeg path configuration
- Improved seeking: video freezes immediately when seeking, resumes when new position is buffered
- Fixed playhead position jump when seeking

### Technical
- LGPL-only FFmpeg build to comply with licensing requirements
- Build script included: `scripts/build-ffmpeg.sh`

## v0.1.0

- Initial release
- Chromecast support with HLS streaming
- Embedded video player with WebView-based HLS playback
- Real-time transcoding for any video format
