# Implementation Tasks

**Scope: UI layer only. BeamyKit is frozen.**

## 1. CastingViewModel - Use Player Protocol
- [x] 1.1 Import Player, MpvPlayer, ChromecastPlayer from BeamyKit
- [x] 1.2 Add `outputType: OutputType` enum (.mpv, .chromecast)
- [x] 1.3 Add `player: Player?` property (via PlayerHandle)
- [x] 1.4 Refactor `isPlaying` to query `player?.isPaused()`
- [x] 1.5 Refactor `currentTime` to query `player?.getPosition()`
- [x] 1.6 Refactor playback controls to call `player?.pause()`, `player?.resume()`, `player?.seek()`
- [x] 1.7 Add `switchOutput(to:)` - stop old player, create new player, preserve position
- [x] 1.8 Add position polling Timer (250ms) that queries player
- [x] 1.9 Load/save outputType and selectedDevice from Config

## 2. ContentView - Output Selector UI
- [x] 2.1 Add segmented control (Picker .segmented) for mpv vs Chromecast
- [x] 2.2 Bind to `viewModel.outputType`
- [x] 2.3 Show Chromecast device button only when outputType == .chromecast
- [x] 2.4 Show "Switching..." status during output switch
- [x] 2.5 Keep drag-and-drop file selection working to start playback

## 3. ChromecastSelectorView - Device Modal
- [x] 3.1 Create new file `ChromecastSelectorView.swift`
- [x] 3.2 Show list of discovered devices (from viewModel.devices)
- [x] 3.3 Add "Rescan" button that calls `viewModel.discoverDevices()`
- [x] 3.4 Show loading indicator during discovery
- [x] 3.5 On device tap, set `viewModel.selectedDevice` and dismiss

## 4. BeamyApp - Keyboard Shortcuts
- [x] 4.1 Add Space → toggle play/pause
- [x] 4.2 Add Left/Right arrows → seek ±10s
- [x] 4.3 Add Cmd+1/2 → switch output to mpv/Chromecast
- [x] 4.4 Add Cmd+S → stop playback

## 5. Testing
- [ ] 5.1 Test mpv output (uses existing MpvPlayer)
- [ ] 5.2 Test Chromecast output (uses existing ChromecastPlayer)
- [ ] 5.3 Test switching mpv ↔ Chromecast preserves position
- [ ] 5.4 Test device selection modal
- [ ] 5.5 Test keyboard shortcuts
- [ ] 5.6 Test config persistence (output type, device)
- [ ] 5.7 Test drag-and-drop loads a video and starts playback
