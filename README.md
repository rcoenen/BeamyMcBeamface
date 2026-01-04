# Beamy

Beamy streams video by running a local transcoder and serving it over HTTP. Playback devices simply consume the live stream.

- If you want the conceptual flow, see `docs/ARCHITECTURE.md`.
- The GUI app is in `Sources/BeamyApp/` and uses BeamyKit for transcoding and streaming.

## Quick Concept

```
[ UI ] -> control -> [ TranscodeServer / FFmpeg ] -> HTTP stream -> [ Chromecast / VLC / In-app preview ]
```

The UI does not control a local file player; it controls the transcoder (play/pause/seek), and clients reflect those changes after a short buffer delay.

### Player Abstraction (Device as Source of Truth)
- TUI controls run through a `Player` protocol (mpv, Chromecast, or server fallback).
- UI state (play/pause/position) is read from the player/device; the transcoder is command-only.
- If player state is temporarily unavailable, the UI shows last-known values instead of transcoder PTS.

## Build & Debug

See `docs/BUILD_DEBUG.md`.
