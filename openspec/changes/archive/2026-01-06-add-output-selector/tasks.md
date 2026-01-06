# Tasks: add-output-selector

## 1. TermKit UI updates
- [ ] Add Output selector control (mpv, chromecast) to the UI layout.
- [ ] Remove automatic player launch on startup; defer until Play pressed.
- [ ] Keep current playback controls visible and functional.

## 2. Player launch/switch logic
- [ ] Implement lazy launch on first Play for selected output.
- [ ] Implement switching outputs: stop current player, start new one, reuse last known position/pause when possible.
- [ ] Ensure cleanup hooks are invoked (mpv quit, Chromecast disconnect) on switch/quit.

## 3. Chromecast selection flow
- [ ] Read preferred Chromecast from TOML; validate availability before use.
- [ ] If missing/unavailable, show discovery modal, list devices, allow selection.
- [ ] Persist chosen Chromecast back to TOML; proceed to play after selection.
- [ ] Handle “no devices found” or connect failures with user-visible status.

## 4. Error handling and UX
- [ ] Surface status messages in UI for launch/connect/discovery failures.
- [ ] Keep session paused when output selection is incomplete or fails.

## 5. Validation
- [ ] Manually test: mpv path (deferred launch), Chromecast path with configured device, Chromecast path requiring discovery.
- [ ] Manually test switching outputs mid-session and resuming position.
