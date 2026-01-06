# Tasks: Add AVPlayer Embedded Playback

## Phase 0: Spec Alignment

### 0.1 Align capability changes into `video-preview`
- [ ] Replace `avplayer-embedded` delta with a delta against `video-preview`
- [ ] Require transcoder start on file drop and embedded player uses transcoder URL
- [ ] Require output switching to reuse the same stream URL
- [ ] Remove external player fallback; embed always uses transcoder
- [ ] Validate change: `openspec validate add-avplayer-embedded-playback --strict`

## Phase 1: Core AVPlayer Implementation

### 1.1 Create AVPlayerView component
- [ ] Create `Sources/BeamyApp/AVPlayerView.swift`
- [ ] Implement SwiftUI view wrapping AVKit VideoPlayer
- [ ] Accept a stream URL (from TranscodeServer)
- [ ] Add isPlaying/currentTime/duration bindings
- [ ] Implement periodic time observer (0.25s interval)
- [ ] Handle onAppear/onDisappear lifecycle
- [ ] Verify: View compiles and shows VideoPlayer

### 1.2 Wire AVPlayerView into ContentView
- [ ] Import AVPlayerView in ContentView.swift
- [ ] Replace MpvPlayerView conditional with AVPlayerView
- [ ] Pass stream URL from viewModel (transcoder)
- [ ] Verify: AVPlayerView appears when output=embedded and file loaded

## Phase 2: ViewModel Integration

### 2.1 Update CastingViewModel for AVPlayer + Transcoder
- [ ] Re-enable `useEmbeddedPlayer = true`
- [ ] Remove MpvPlayerView-specific coordinator code
- [ ] Start/keep TranscodeServer running on file drop
- [ ] Surface transcoder stream URL to the view
- [ ] Create AVPlayer with stream URL; no external fallback
- [ ] Verify: File drop creates AVPlayer streaming transcoder output

### 2.2 Implement playback controls
- [ ] Connect `togglePlayPause()` to AVPlayer
- [ ] Connect `skipForward()` to AVPlayer seek
- [ ] Connect `skipBackward()` to AVPlayer seek
- [ ] Connect `seekToProgress()` to AVPlayer seek
- [ ] Verify: All controls work with embedded player

### 2.3 Implement position tracking
- [ ] Subscribe to AVPlayer time observer in ViewModel
- [ ] Update `embeddedCurrentTime` from observer
- [ ] Update `embeddedDuration` from AVPlayer item (if available from stream)
- [ ] Update `embeddedIsPlaying` from AVPlayer rate
- [ ] Verify: Seek bar updates during playback

## Phase 3: Output Switching

### 3.1 Embedded to Chromecast handoff (shared transcoder)
- [ ] Capture position from AVPlayer before switch
- [ ] Pause AVPlayer on switch to Chromecast
- [ ] Seek TranscodeServer to captured position (if needed)
- [ ] Verify: Position preserved when switching to Chromecast

### 3.2 Chromecast to AVPlayer handoff
- [ ] Get position from Chromecast before switch
- [ ] Stop Chromecast playback
- [ ] Seek AVPlayer to captured position
- [ ] Resume AVPlayer playback
- [ ] Verify: Position preserved when switching to local

## Phase 4: Unsupported Format Handling

### 4.1 Remove external player fallback
- [ ] Delete/disable external mpv fallback paths
- [ ] Ensure embedded always uses transcoder stream
- [ ] Verify: Unsupported formats still play via transcoder stream

### 4.2 User feedback for format issues
- [ ] Show clear error when format unsupported and no mpv available
- [ ] Log format detection results for debugging
- [ ] Verify: User understands why embedded player not used

## Phase 5: Cleanup & Polish

### 5.1 Trim unused mpv embedded code paths
- [ ] Remove or archive MpvPlayerView.swift (keep for reference) once AVPlayer path is stable
- [ ] Remove mpv-specific bindings from ViewModel if unused
- [ ] Update EmbeddedPlayer.md with implementation status
- [ ] Verify: No dead code remains

### 5.2 Update documentation
- [ ] Update EmbeddedPlayer.md conclusion with "Implemented" status
- [ ] Document supported vs unsupported formats
- [ ] Add troubleshooting section for format issues and on-demand transcoder behavior
- [ ] Verify: Documentation matches implementation

## Dependencies

```
Phase 1 ──→ Phase 2 ──→ Phase 3
                ↓
            Phase 4
                ↓
            Phase 5
```

- Phase 2 depends on Phase 1 (AVPlayerView must exist)
- Phase 3 depends on Phase 2 (controls must work)
- Phase 4 can parallel Phase 3 (independent fallback logic)
- Phase 5 depends on all above (cleanup after feature complete)

## Validation Criteria

- [ ] MP4 file plays embedded in app window
- [ ] MOV file plays embedded in app window
- [ ] MKV file falls back to external mpv (or shows error)
- [ ] No crashes during window focus/activation
- [ ] Seek bar updates during playback
- [ ] Play/pause works correctly
- [ ] Skip forward/backward works correctly
- [ ] Output switch to Chromecast preserves position (±2s)
- [ ] Output switch from Chromecast preserves position (±2s)
