# Spec: Output Switching

## ADDED Requirements

### Requirement: Output switching MUST preserve playback position within 2 seconds

When the user switches between mpv and Chromecast output, the system SHALL preserve the playback position with a maximum drift of 2 seconds.

**Related**: position-tracking, chromecast-reliability

#### Scenario: Switch from mpv to Chromecast preserves position
**Given** video is playing via mpv at 45.2s
**When** user selects "Chromecast (Bedroom TV)" output
**Then** mpv player is queried for current position (returns 45.2s)
**And** mpv player is stopped and cleaned up
**And** Chromecast player is launched
**And** Chromecast seeks to 45.2s
**And** final Chromecast position is between 43.2s and 47.2s (±2s)

#### Scenario: Switch from Chromecast to mpv preserves position
**Given** video is playing via Chromecast at 120.5s
**When** user selects "mpv" output
**Then** Chromecast player is queried for current position (returns 120.5s)
**And** Chromecast player is disconnected and cleaned up
**And** mpv player is launched
**And** mpv seeks to 120.5s
**And** final mpv position is between 118.5s and 122.5s (±2s)

#### Scenario: Position query fails during switch
**Given** video is playing via mpv at 30.0s
**And** `lastKnownPosition` is cached as 30.0s
**When** user switches to Chromecast
**And** `player.getPosition()` throws PlayerError.statusUnavailable
**Then** system falls back to `lastKnownPosition` (30.0s)
**And** Chromecast seeks to 30.0s
**And** switch completes successfully

### Requirement: Output switching MUST prevent concurrent switches

The TermKitTranscoderUI SHALL prevent multiple simultaneous output switches to avoid race conditions and state corruption.

**Related**: output-switching

#### Scenario: Second switch attempt is blocked during in-progress switch
**Given** user is switching from mpv to Chromecast (in progress)
**When** user attempts to switch back to mpv before first switch completes
**Then** second switch is ignored
**And** log shows: "Output switch already in progress"
**And** status label shows: "Status: switching output..."
**And** first switch completes normally

#### Scenario: Switch can proceed after previous switch completes
**Given** user switched from mpv to Chromecast (completed)
**When** user switches back to mpv
**Then** switch proceeds normally
**And** `isSwitchingOutput` flag is set/cleared correctly

### Requirement: Output switching MUST show visual feedback to user

The TermKitTranscoderUI SHALL display a status message during output switching to indicate the operation is in progress.

**Related**: output-switching

#### Scenario: Status label shows switching message
**Given** user is viewing the TUI
**When** user selects Chromecast output
**Then** status label immediately shows: "Status: switching output..."
**And** status persists during player cleanup and launch
**When** switch completes successfully
**Then** status label updates to: "Status: Chromecast set to Bedroom TV"

#### Scenario: Status label shows error on switch failure
**Given** user selects Chromecast output
**When** switch fails due to connection error
**Then** status label shows: "Status: Chromecast error <error message>"
**And** output reverts to previous player (mpv)

### Requirement: Output switching MUST validate position accuracy after switch

After switching outputs, the system SHALL query the new player's position and log a warning if the position differs from the expected position by more than 2 seconds.

**Related**: position-tracking, output-switching

#### Scenario: Position validation succeeds after switch
**Given** video was at 60.0s before switch
**When** switch to Chromecast completes
**And** `player.getPosition()` returns 60.5s
**Then** no warning is logged (drift is 0.5s < 2s threshold)

#### Scenario: Position validation detects drift after switch
**Given** video was at 60.0s before switch
**When** switch to Chromecast completes
**And** `player.getPosition()` returns 55.0s
**Then** warning is logged: "Position drift after switch: expected 60.0s, got 55.0s"
**And** playback continues from 55.0s (no automatic correction)

#### Scenario: Position validation skipped if query fails
**Given** video was at 60.0s before switch
**When** switch to Chromecast completes
**And** `player.getPosition()` throws error
**Then** no warning is logged (validation skipped)
**And** playback continues normally

### Requirement: Pause state MUST be preserved across output switches

When switching outputs, the system SHALL preserve the paused/playing state from the old player to the new player.

**Related**: output-switching

#### Scenario: Switching while paused keeps new player paused
**Given** video is playing via mpv at 30s
**And** user pauses playback
**When** user switches to Chromecast output
**Then** Chromecast player is launched
**And** Chromecast seeks to 30s
**And** Chromecast player is paused (via `player.pause()`)
**And** playback does not auto-resume

#### Scenario: Switching while playing keeps new player playing
**Given** video is playing via mpv at 30s
**When** user switches to Chromecast output
**Then** Chromecast player is launched
**And** Chromecast seeks to 30s
**And** Chromecast player resumes playback
**And** video continues playing

## MODIFIED Requirements

None - this change only adds validation to existing switch logic.

## REMOVED Requirements

None - no existing functionality is removed.
