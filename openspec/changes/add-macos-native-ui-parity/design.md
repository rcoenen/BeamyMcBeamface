# Design: macOS Native UI (UI Layer Only)

## Context

The BeamyKit backend is complete and tested via TUI:
- `Player` protocol with `MpvPlayer` and `ChromecastPlayer` ✅
- `TranscodeServer` for FFmpeg management ✅
- `ChromecastDiscovery` and `CastV2Client` ✅
- Position tracking, output switching, pause preservation ✅

The current BeamyApp GUI doesn't use these. It talks directly to TranscodeServer and can be replaced entirely (keep the drag-and-drop entry point for file selection). Behavioral reference is the TermKit TUI (minus drag-and-drop).

**Mission:** Make BeamyApp use the same BeamyKit APIs that TUI uses.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│              BeamyApp (SwiftUI) - MODIFY THIS       │
│                                                     │
│  ┌──────────────┐  ┌─────────────────────────────┐ │
│  │ ContentView  │  │   CastingViewModel          │ │
│  │              │  │                             │ │
│  │ - Output     │◄─┤ - outputType: .mpv|.cc     │ │
│  │   Selector   │  │ - player: Player?           │ │
│  │ - Device Btn │  │ - transcodeServer           │ │
│  │ - Controls   │  │                             │ │
│  └──────────────┘  │ - switchOutput(to:)         │ │
│                    │ - poll player every 250ms   │ │
│  ┌──────────────┐  └─────────────────────────────┘ │
│  │ Chromecast   │                                  │
│  │ Modal Sheet  │                                  │
│  └──────────────┘                                  │
└────────────────────────────┬───────────────────────┘
                             │
                             │ calls existing APIs
                             ▼
┌─────────────────────────────────────────────────────┐
│              BeamyKit - DO NOT TOUCH                │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │ Player Protocol                              │   │
│  │   - getPosition() -> TimeInterval            │   │
│  │   - getDuration() -> TimeInterval            │   │
│  │   - isPaused() -> Bool                       │   │
│  │   - pause(), resume(), seek(to:)             │   │
│  └─────────────────────────────────────────────┘   │
│         ▲                           ▲              │
│         │                           │              │
│  ┌──────┴──────┐             ┌──────┴──────┐      │
│  │  MpvPlayer  │             │ChromecastPlayer│   │
│  │  (IPC)      │             │  (CastV2)    │      │
│  └─────────────┘             └──────────────┘      │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │ TranscodeServer (FFmpeg)                     │   │
│  │ ChromecastDiscovery                          │   │
│  │ Config (beamy.toml)                          │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## What CastingViewModel Needs To Do

**Current (wrong):**
```swift
// Talks to TranscodeServer directly
var isPlaying: Bool { !(transcodeServer?.isPaused ?? true) }
var currentTime: TimeInterval { transcodeServer?.currentPosition ?? 0 }
```

**After (correct - copy from TUI):**
```swift
// Talks to Player protocol
var player: Player?
var isPlaying: Bool { !(player?.isPaused() ?? true) }
var currentTime: TimeInterval { player?.getPosition() ?? 0 }

func switchOutput(to type: OutputType) {
    let position = player?.getPosition() ?? 0
    let wasPaused = player?.isPaused() ?? false

    // Stop old player
    player = nil

    // Create new player (MpvPlayer or ChromecastPlayer)
    player = type == .mpv
        ? MpvPlayer(url: transcodeServer.url)
        : ChromecastPlayer(device: selectedDevice, url: transcodeServer.url)

    // Restore state
    player?.seek(to: position)
    if wasPaused { player?.pause() }
}
```

## Reference: How TUI Does It

Look at `TermKitTranscoderUI.swift` for patterns:
- Line ~100: `var player: Player?`
- Line ~200: Output switching with position preservation
- Line ~300: Timer polling `player?.getPosition()`
- Line ~400: Chromecast device modal

Copy the patterns, adapt for SwiftUI.

## Files to Modify

| File | Change |
|------|--------|
| `CastingViewModel.swift` | Add Player, outputType, switchOutput(), timer |
| `ContentView.swift` | Add output selector, device button |
| `ChromecastSelectorView.swift` | NEW - modal for device selection |
| `BeamyApp.swift` | Keyboard shortcuts |

## Files NOT to Modify

- Everything in `Sources/BeamyKit/*`
- `TermKitTranscoderUI.swift` (reference only)
