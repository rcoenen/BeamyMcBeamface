# Change: Replace TUI with macOS Native UI

## Why

The TUI (TermKitTranscoderUI) was used to build and test the BeamyKit backend (Player protocol, MpvPlayer, ChromecastPlayer, TranscodeServer, Chromecast discovery). The backend is now complete and proven. Time to put a proper native macOS UI on top of it.

## What Changes

**Scope: UI layer ONLY. Do not touch BeamyKit.**

Replace the TermKit TUI with a native SwiftUI macOS app that calls the same BeamyKit APIs.

```
BEFORE:  TUI (TermKit) → BeamyKit (Player, TranscodeServer, etc.)
AFTER:   macOS UI (SwiftUI) → BeamyKit (Player, TranscodeServer, etc.)
```

**BeamyApp changes:**
- Refactor `CastingViewModel` to use `Player` protocol (like TUI does)
- Add output selector UI (mpv vs Chromecast)
- Add Chromecast device selection modal (like TUI has)
- Wire up existing BeamyKit APIs to SwiftUI controls

**NOT changing:**
- `BeamyKit/*` - All backend code stays untouched
- `Player.swift`, `MpvPlayer.swift`, `ChromecastPlayer.swift` - Already work
- `TranscodeServer.swift` - Already works
- `ChromecastDiscovery.swift`, `CastV2Client.swift` - Already work

## Impact

**Affected code (UI only, replace old macOS UI entirely; keep drag-and-drop for file selection):**
- `Sources/BeamyApp/CastingViewModel.swift` - Use Player protocol
- `Sources/BeamyApp/ContentView.swift` - Add output selector
- `Sources/BeamyApp/ChromecastSelectorView.swift` - NEW modal
- `Sources/BeamyApp/BeamyApp.swift` - Keyboard shortcuts

**NOT affected:**
- `Sources/BeamyKit/*` - DO NOT TOUCH
- `Sources/Beamy/Commands/TermKitTranscoderUI.swift` - Reference only
