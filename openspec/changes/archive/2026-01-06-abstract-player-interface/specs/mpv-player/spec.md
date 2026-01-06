# Spec: MpvPlayer Implementation

## ADDED Requirements

### Requirement: System SHALL provide MpvPlayer wrapping MpvController

The system SHALL provide an MpvPlayer class that implements the Player protocol by wrapping an existing MpvController instance, delegating all operations to the controller.

#### Scenario: Delegate position query to MpvController
**Given** an MpvPlayer wrapping an MpvController
**When** `getPosition()` is called
**Then** it calls `controller.getPosition()`
**And** returns the result or propagates the error

#### Scenario: Delegate pause state query to MpvController
**Given** an MpvPlayer wrapping an MpvController
**When** `isPaused()` is called
**Then** it calls `controller.isPaused()`
**And** returns the result or propagates the error

#### Scenario: Delegate playback control to MpvController
**Given** an MpvPlayer wrapping an MpvController
**When** `pause()`, `resume()`, or `seek(to:)` is called
**Then** it calls the corresponding MpvController method
**And** propagates any errors

### Requirement: MpvPlayer SHALL handle position calculation for stream reloads

MpvPlayer SHALL internally track seek positions and calculate actual position as `lastSeekTarget + mpv.playback-time` to handle mpv's playback-time reset after stream reloads.

**Related**: player-protocol

#### Scenario: Calculate position after seek with reload
**Given** MpvPlayer performed a seek to 300 seconds with stream reload
**And** mpv's playback-time reset to 0 and is now at 2.5 seconds
**When** `getPosition()` is called
**Then** it returns 302.5 seconds (300 + 2.5)

#### Scenario: Track last seek target
**Given** MpvPlayer is at position 100 seconds
**When** `seek(to: 200)` is called
**Then** MpvPlayer stores 200 as `lastSeekTarget`
**And** subsequent `getPosition()` uses this for calculation

### Requirement: MpvPlayer SHALL preserve pause state across reloads

MpvPlayer SHALL preserve pause state when reloading streams, pausing playback after reload if it was paused before.

**Related**: player-protocol

#### Scenario: Restore pause after seek with reload
**Given** MpvPlayer is paused
**When** `seek(to: 150)` is called (triggering stream reload)
**Then** after reload completes, playback is paused
**And** `isPaused()` returns `true`

#### Scenario: Keep playing after seek when not paused
**Given** MpvPlayer is playing
**When** `seek(to: 150)` is called (triggering stream reload)
**Then** after reload completes, playback continues
**And** `isPaused()` returns `false`

### Requirement: MpvPlayer SHALL NOT modify MpvController

MpvPlayer SHALL be implemented as a wrapper without modifying the existing MpvController class, ensuring backward compatibility.

#### Scenario: Use existing MpvController unchanged
**Given** the current MpvController implementation
**When** MpvPlayer is implemented
**Then** MpvController code remains unchanged
**And** all existing MpvController functionality works identically

### Requirement: MpvPlayer SHALL support position extrapolation for smooth UI

MpvPlayer SHALL support light position extrapolation between device queries to provide smooth UI updates, similar to VLC's approach (optional feature).

**Related**: player-protocol, VLC Chromecast implementation

#### Scenario: Extrapolate position between queries
**Given** MpvPlayer last queried device at time T0, receiving position 100.0
**And** current time is T0 + 0.5 seconds
**When** `getPosition()` is called before next device query
**Then** it MAY return extrapolated position (100.5 seconds)
**And** extrapolation uses: lastDevicePosition + (now - lastQueryTime)

#### Scenario: Refresh from device periodically
**Given** MpvPlayer is extrapolating position
**When** sufficient time has passed since last device query
**Then** it queries `controller.getPosition()` to refresh actual device state
**And** resets extrapolation baseline to new device-reported position
