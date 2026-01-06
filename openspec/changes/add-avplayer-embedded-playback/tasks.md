# Tasks: Add AVPlayer Embedded Playback

## Phase 0: Spec Alignment

### 0.1 Merge capability changes into `video-preview`
- [ ] Replace `avplayer-embedded` delta with a delta against `video-preview`
- [ ] Add output-switching scenario for on-demand TranscodeServer startup
- [ ] Add unsupported-format fallback scenario for external mpv
- [ ] Validate change: `openspec validate add-avplayer-embedded-playback --strict`

## Phase 1: Core AVPlayer Implementation

### 1.1 Create AVPlayerView component
- [ ] Create `Sources/BeamyApp/AVPlayerView.swift`
- [ ] Implement SwiftUI view wrapping AVKit VideoPlayer
- [ ] Add URL binding for video source
- [ ] Add isPlaying binding for play/pause state
- [ ] Add currentTime binding for position tracking
- [ ] Add duration binding for total length
- [ ] Implement periodic time observer (0.25s interval)
- [ ] Handle onAppear/onDisappear lifecycle
- [ ] Verify: View compiles and shows VideoPlayer

### 1.2 Add format detection helper
- [ ] Create `canPlay(url:)` static method on AVPlayerView
- [ ] Pre-filter extensions and confirm with `AVURLAsset(url:).isPlayable`
- [ ] Return false for MKV, WebM, AVI
- [ ] Verify: Returns correct values for test files

### 1.3 Wire AVPlayerView into ContentView
- [ ] Import AVPlayerView in ContentView.swift
- [ ] Replace MpvPlayerView conditional with AVPlayerView
- [ ] Pass appropriate bindings from viewModel
- [ ] Verify: AVPlayerView appears when output=mpv and file loaded

## Phase 2: ViewModel Integration

### 2.1 Update CastingViewModel for AVPlayer
- [ ] Re-enable `useEmbeddedPlayer = true`
- [ ] Remove MpvPlayerView-specific coordinator code
- [ ] Add AVPlayer instance management
- [ ] Update `handleFileDrop` to check format support with `isPlayable`
- [ ] Verify: File drop creates AVPlayer for supported formats; unsupported falls back cleanly

### 2.2 Implement playback controls
- [ ] Connect `togglePlayPause()` to AVPlayer
- [ ] Connect `skipForward()` to AVPlayer seek
- [ ] Connect `skipBackward()` to AVPlayer seek
- [ ] Connect `seekToProgress()` to AVPlayer seek
- [ ] Verify: All controls work with embedded player

### 2.3 Implement position tracking
- [ ] Subscribe to AVPlayer time observer in ViewModel
- [ ] Update `embeddedCurrentTime` from observer
- [ ] Update `embeddedDuration` from AVPlayer item
- [ ] Update `embeddedIsPlaying` from AVPlayer rate
- [ ] Verify: Seek bar updates during playback

## Phase 3: Output Switching

### 3.1 AVPlayer to Chromecast handoff (on-demand TranscodeServer)
- [ ] Capture position from AVPlayer before switch
- [ ] Pause AVPlayer on switch to Chromecast
- [ ] Start TranscodeServer if not running; seek to captured position
- [ ] Verify: Position preserved when switching to Chromecast

### 3.2 Chromecast to AVPlayer handoff
- [ ] Get position from Chromecast before switch
- [ ] Stop Chromecast playback
- [ ] Seek AVPlayer to captured position
- [ ] Resume AVPlayer playback
- [ ] Verify: Position preserved when switching to local

## Phase 4: Unsupported Format Handling

### 4.1 External mpv fallback
- [ ] Detect unsupported format via `canPlay(url:)`
- [ ] Fall back to external MpvPlayer with file URL for unsupported formats
- [ ] Show info message "Playing in external window (format not supported)"
- [ ] Verify: MKV files open in external mpv and controls remain responsive

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
