# Proposal: Add AVPlayer Embedded Playback

## Change ID
`add-avplayer-embedded-playback`

## Summary
Replace the crashed NSOpenGLView-based mpv embedded player with Apple's native AVPlayer/AVKit for embedded video playback in the macOS SwiftUI app, and always feed it the transcoder stream (same stream Chromecast uses).

## Background

### Problem
The current MpvPlayerView (using NSOpenGLView + libmpv) crashes when embedded in SwiftUI due to:
- NSOpenGLView cannot be layer-backed
- SwiftUI views are layer-backed by default
- This mismatch causes `_CUIThemeFacetCacheKey` crash during window activation

See `EmbeddedPlayer.md` for full analysis.

### Solution
Use AVPlayer (Apple's native video framework) to play the transcoder output stream for all embedded playback. Start the existing FFmpeg-based `TranscodeServer` immediately on file drop (or on-demand if not running) and point both the embedded player and Chromecast at the same stream URL so behavior matches across outputs. Remove external mpv fallback.

## Scope

### In Scope
1. **AVPlayer-based embedded player view** - SwiftUI view using AVKit's VideoPlayer
2. **Transcoder-backed playback** - Always play the transcoder stream URL internally
3. **Playback controls integration** - Play/pause, seek, position tracking via AVPlayer
4. **Output switching** - `TranscodeServer` feeds both embedded player and Chromecast; switching uses the same stream URL with position preservation

### Out of Scope
- Chromecast stream preview (monitoring transcoded output in embedded player)
- Changing TranscodeServer output format (Matroska works for Chromecast)
- VLCKit or other third-party players

## Design Rationale

### Why AVPlayer for Embedded Playback?
- AVPlayer integrates cleanly with SwiftUI via `VideoPlayer`
- No external dependencies or NSOpenGL embedding issues
- Plays HTTP streams when the transcoder outputs an AVPlayer-friendly format
- Using the transcoder stream keeps behavior identical between embedded player and Chromecast

### Stream Format
- TranscodeServer must emit an AVPlayer-compatible stream (e.g., HLS/fMP4)
- Chromecast consumes the same stream (or a compatible variant) from the transcoder URL

### Architecture (Single Stream from Transcoder)

```
┌─────────────────────────────────────────────────────────────┐
│ ContentView                                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Output = Embedded        │ Output = Chromecast      │    │
│  │  ┌───────────────────┐   │  ┌───────────────────┐  │    │
│  │  │ AVPlayerView      │   │  │ Chromecast Client │  │    │
│  │  │ - loads transcoder│   │  │ - loads same URL  │  │    │
│  │  │   stream URL      │   │  │                   │  │    │
│  │  └───────────────────┘   │  └───────────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ TranscodeServer (FFmpeg) started on file drop       │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ PlaybackControlsView (unified for both outputs)     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Capabilities Affected

### Modified Capability: `video-preview`
- Embed AVPlayer for playback of the transcoder stream (always)
- No external player fallback

### Modified Capability: `output-switching`
- Start/stop `TranscodeServer` as needed, but both embedded and Chromecast consume the same stream URL

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| AVPlayer codec support limited | Medium | For unsupported formats (MKV), fall back to external mpv or transcode |
| Different behavior than mpv | Low | Document differences, match core functionality |
| Position tracking differences | Low | Use AVPlayer's native `currentTime` observer |

## Success Criteria
1. Video files play embedded in app window when output = mpv
2. No crashes during window activation/focus changes
3. Seek bar and playback controls work correctly
4. Position tracking updates in real-time
5. Output switching preserves playback position where possible
