# position-tracking Specification

## Purpose
TBD - created by archiving change harden-chromecast-playback. Update Purpose after archive.
## Requirements
### Requirement: ChromecastPlayer MUST provide accurate position within 1 second

The ChromecastPlayer SHALL return the current playback position accurate to within 1 second of the actual Chromecast playback time.

**Related**: chromecast-reliability

#### Scenario: Position query returns recent MEDIA_STATUS
**Given** Chromecast is playing at 45.2s (actual device time)
**And** MEDIA_STATUS last updated 0.5s ago with currentTime = 44.7s
**When** `player.getPosition()` is called
**Then** method returns 44.7s (stale by 0.5s)
**And** accuracy is within 1s of actual (45.2s - 44.7s = 0.5s < 1s)

#### Scenario: Position query with stale MEDIA_STATUS
**Given** Chromecast is playing at 50.0s (actual device time)
**And** MEDIA_STATUS last updated 3.0s ago with currentTime = 47.0s
**When** `player.getPosition()` is called
**Then** method returns 47.0s (stale by 3s)
**And** accuracy exceeds 1s tolerance (50.0s - 47.0s = 3s > 1s)
**And** system triggers fresh position request

### Requirement: Position updates MUST be requested at least every 1 second during playback

When Chromecast is actively playing, the TermKitTranscoderUI SHALL request fresh position updates at least once per second to maintain accuracy.

**Related**: position-tracking

#### Scenario: Active polling during playback
**Given** Chromecast is playing video
**When** TUI timer ticks (every 0.5s)
**And** player is ChromecastPlayer
**And** player state is "PLAYING"
**Then** system sends GET_STATUS request to Chromecast
**And** fresh MEDIA_STATUS is received within 200ms
**And** `latestMediaStatus` is updated
**And** UI displays current accurate position

#### Scenario: No polling when paused
**Given** Chromecast is paused at 30s
**When** TUI timer ticks (every 0.5s)
**And** player is ChromecastPlayer
**And** player state is "PAUSED"
**Then** no GET_STATUS request is sent
**And** position remains 30s (no change expected)
**And** network traffic is minimized

#### Scenario: No polling when using mpv
**Given** video is playing via mpv
**When** TUI timer ticks (every 0.5s)
**And** player is MpvPlayer
**Then** no Chromecast GET_STATUS request is sent
**And** mpv's native position is queried instead

### Requirement: Position interpolation SHALL be used to improve smoothness

The ChromecastPlayer SHALL interpolate position between MEDIA_STATUS updates when the player state is "PLAYING" to provide smoother progress bar updates.

**Related**: position-tracking

#### Scenario: Interpolation during playback
**Given** MEDIA_STATUS last updated 1.5s ago with:
  - currentTime = 100.0s
  - playerState = "PLAYING"
**When** `player.getPosition()` is called
**Then** method calculates elapsed time since last update (1.5s)
**And** returns interpolated position: 100.0 + 1.5 = 101.5s
**And** position is smoother than waiting for next MEDIA_STATUS

#### Scenario: No interpolation when paused
**Given** MEDIA_STATUS last updated 2.0s ago with:
  - currentTime = 50.0s
  - playerState = "PAUSED"
**When** `player.getPosition()` is called
**Then** method returns exact value from MEDIA_STATUS: 50.0s
**And** no interpolation is applied (position should not advance when paused)

#### Scenario: Interpolation clamped by duration
**Given** video duration is 120.0s
**And** MEDIA_STATUS last updated 5.0s ago with:
  - currentTime = 118.0s
  - playerState = "PLAYING"
**When** `player.getPosition()` is called
**Then** interpolated position would be 118.0 + 5.0 = 123.0s
**And** method clamps to duration: returns 120.0s
**And** does not return position beyond video end

### Requirement: Position drift MUST be detected and logged

The system SHALL detect when the Chromecast position differs significantly from the TranscodeServer position and log warnings for debugging.

**Related**: position-tracking, chromecast-reliability

#### Scenario: Normal position alignment
**Given** TranscodeServer reports position 60.5s
**And** ChromecastPlayer reports position 60.2s
**When** drift detection runs
**Then** difference is 0.3s (< 3s threshold)
**And** no warning is logged
**And** positions are considered aligned

#### Scenario: Position drift exceeds threshold
**Given** TranscodeServer reports position 75.0s
**And** ChromecastPlayer reports position 68.0s
**When** drift detection runs
**Then** difference is 7.0s (> 3s threshold)
**And** warning is logged: "Position drift detected: server 75.0s, player 68.0s (drift: 7.0s)"
**And** no automatic correction is applied (log only)

#### Scenario: Drift detection disabled during seeks
**Given** user is actively seeking (within 2s of seek command)
**When** drift detection runs
**Then** detection is skipped (position mismatch expected during seek)
**And** no warning is logged

### Requirement: TUI timer MUST update position display every 500ms

The TermKitTranscoderUI timer SHALL query the active player's position every 500ms and update the time/progress displays.

**Related**: position-tracking

#### Scenario: Position display updates during playback
**Given** video is playing via Chromecast at 30.0s
**When** timer ticks at T+0.0s
**Then** `player.getPosition()` returns 30.0s
**And** time label shows: "Time: 00:30 / 02:00"
**And** progress bar shows: "15%"
**When** timer ticks at T+0.5s
**Then** `player.getPosition()` returns 30.5s
**And** time label shows: "Time: 00:30 / 02:00" (rounded to second)
**And** progress bar shows: "15%" (incremental update)

#### Scenario: Position display frozen when paused
**Given** video is paused via Chromecast at 45.0s
**When** timer ticks every 0.5s
**Then** `player.getPosition()` consistently returns 45.0s
**And** time label remains: "Time: 00:45 / 02:00"
**And** progress bar remains: "37%"

