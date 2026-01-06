# Tasks: Seekable Video Preview with Playback Controls

## 1. Local Preview (Original File)
- [ ] 1.1 Update `handleFileDrop` to create AVPlayer with `file://` URL (not HTTP)
- [ ] 1.2 Get duration from MediaInfo and store in ViewModel
- [ ] 1.3 Add AVPlayer time observer for current position updates
- [ ] 1.4 Implement play/pause toggle for AVPlayer
- [ ] 1.5 Implement seek for AVPlayer using `seek(to: CMTime)`
- [ ] 1.6 Test that local preview works with full seeking on macOS 26.1

## 2. Playback Controls UI
- [ ] 2.1 Create `PlaybackControlsView` component
- [ ] 2.2 Add seek bar (Slider) bound to progress
- [ ] 2.3 Add time display: current time / total duration
- [ ] 2.4 Add time remaining display
- [ ] 2.5 Add Play/Pause button with appropriate icon
- [ ] 2.6 Add 10-second skip forward/backward buttons
- [ ] 2.7 Style controls to match app theme

## 3. TranscodeServer Enhancements
- [ ] 3.1 Add `startPosition` parameter to track seek position
- [ ] 3.2 Modify FFmpeg command to use `-ss <time>` before `-i` for seeking
- [ ] 3.3 Implement `seek(to: TimeInterval)` - kill FFmpeg, restart at position
- [ ] 3.4 Implement `pause()` - send SIGSTOP to FFmpeg process
- [ ] 3.5 Implement `resume()` - send SIGCONT to FFmpeg process
- [ ] 3.6 Handle edge cases (seek while paused, seek to end, etc.)

## 4. Chromecast Playback Controls
- [ ] 4.1 Add seek support to Caster - restart stream at new position
- [ ] 4.2 Add pause/resume to Caster - control FFmpeg via signals
- [ ] 4.3 Parse MEDIA_STATUS from Chromecast for current position
- [ ] 4.4 Sync ViewModel state with Chromecast playback state
- [ ] 4.5 Handle Chromecast reconnection after seek

## 5. ViewModel State Management
- [ ] 5.1 Add `@Published var currentTime: TimeInterval`
- [ ] 5.2 Add `@Published var duration: TimeInterval`
- [ ] 5.3 Add `@Published var isPlaying: Bool`
- [ ] 5.4 Add computed `progress` and `timeRemaining` properties
- [ ] 5.5 Add `play()`, `pause()`, `seek(to:)` methods
- [ ] 5.6 Handle state sync between local preview and Chromecast modes

## 6. Time Formatting
- [ ] 6.1 Create time formatter: `01:23:45` for hours, `23:45` for < 1 hour
- [ ] 6.2 Format time remaining with minus sign: `-00:51:15`
- [ ] 6.3 Handle edge cases (0:00, negative, > 24 hours)

## 7. Testing & Polish
- [ ] 7.1 Test local preview seeking with various formats
- [ ] 7.2 Test Chromecast seek (verify 1-2s latency)
- [ ] 7.3 Test pause/resume for both local and Chromecast
- [ ] 7.4 Test seek while paused
- [ ] 7.5 Test rapid seeking (debounce if needed)
- [ ] 7.6 Add loading indicator during Chromecast seek
- [ ] 7.7 Clean up debug code
