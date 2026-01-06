# Proposal: Add AVPlayer Embedded Playback

## Change ID
`add-avplayer-embedded-playback`

## Summary
Replace the crashed NSOpenGLView-based mpv embedded player with Apple's native AVPlayer/AVKit for embedded video playback in the macOS SwiftUI app, keeping local playback on the original file and starting the transcoder only when handing off to Chromecast.

## Background

### Problem
The current MpvPlayerView (using NSOpenGLView + libmpv) crashes when embedded in SwiftUI due to:
- NSOpenGLView cannot be layer-backed
- SwiftUI views are layer-backed by default
- This mismatch causes `_CUIThemeFacetCacheKey` crash during window activation

See `EmbeddedPlayer.md` for full analysis.

### Solution
Use AVPlayer (Apple's native video framework) for local playback of the original file (best quality, no transcode), and start the existing FFmpeg-based `TranscodeServer` on-demand when switching to Chromecast so the cast path still uses Matroska/HLS output. This keeps local playback fast while ensuring Chromecast still has a stream to load.

## Scope

### In Scope
1. **AVPlayer-based embedded player view** - SwiftUI view using AVKit's VideoPlayer
2. **Local file playback** - Play original video files directly (no transcoding needed for local playback)
3. **Playback controls integration** - Play/pause, seek, position tracking via AVPlayer
4. **Output switching** - On-demand `TranscodeServer` startup when switching from local AVPlayer to Chromecast, preserving position

### Out of Scope
- Chromecast stream preview (monitoring transcoded output in embedded player)
- Changing TranscodeServer output format (Matroska works for Chromecast)
- VLCKit or other third-party players

## Design Rationale

### Why AVPlayer for Local Playback?
When output type is "mpv" (local), we don't need transcoding at all:
- AVPlayer can play most video formats directly (MP4, MOV, M4V)
- For formats AVPlayer doesn't support (MKV), we transcode on-demand
- This matches the existing `video-preview` spec which states "video plays from the original file (not transcoded)"

### Why Not AVPlayer for Chromecast Monitoring?
- TranscodeServer outputs Matroska format (AVPlayer doesn't support MKV)
- Changing to HLS/fMP4 would require significant TranscodeServer changes
- Chromecast playback doesn't need local preview (it's on the TV)
- Can add this later if needed

### Architecture (Option B: on-demand transcoder)

```
┌─────────────────────────────────────────────────────────────┐
│ ContentView                                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Output = Local (mpv)     │ Output = Chromecast      │    │
│  │  ┌───────────────────┐   │  ┌───────────────────┐  │    │
│  │  │ AVPlayerView      │   │  │ Chromecast Client │  │    │
│  │  │ - original file   │   │  │ - loads server    │  │    │
│  │  │ - native controls │   │  │   URL when needed │  │    │
│  │  └───────────────────┘   │  └───────────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ TranscodeServer (FFmpeg) started only for casting   │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ PlaybackControlsView (unified for both outputs)     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Capabilities Affected

### Modified Capability: `video-preview`
- Embed AVPlayer for local playback of the original file
- On unsupported formats, fall back to external mpv (file path)

### Modified Capability: `output-switching`
- Start/stop `TranscodeServer` on demand when switching to/from Chromecast

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
