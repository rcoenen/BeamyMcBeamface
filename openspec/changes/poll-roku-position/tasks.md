# Tasks

- [ ] Add `queryMediaPlayer()` method to `RokuPlayer.swift` that fetches and parses `/query/media-player` XML
- [ ] Add `rokuPolledPosition: TimeInterval?` property to `CastingViewModel`
- [ ] Add polling timer that calls `queryMediaPlayer()` every 1 second when Roku is active
- [ ] Update `currentTime` computed property to prefer `rokuPolledPosition` over estimation
- [ ] Update `isPlaying` to use polled state when available
- [ ] Stop polling timer when switching away from Roku or stopping playback
- [ ] Test: play video, verify progress bar matches actual Roku position
- [ ] Test: pause on Roku remote, verify UI updates
- [ ] Remove elapsed time estimation code (or keep as fallback)
- [ ] Update ROKU.md to remove "Progress Bar is Estimated" limitation
