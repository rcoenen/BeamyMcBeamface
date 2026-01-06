# Spec: ChromecastPlayer Implementation

## ADDED Requirements

### Requirement: System SHALL provide ChromecastPlayer that parses MEDIA_STATUS messages

The system SHALL provide a ChromecastPlayer that implements the Player protocol by parsing MEDIA_STATUS messages received from the Chromecast device via CastV2Client.

**Related**: player-protocol

#### Scenario: Extract position from MEDIA_STATUS
**Given** Chromecast sent a MEDIA_STATUS with `currentTime: 45.67`
**When** ChromecastPlayer `getPosition()` is called
**Then** it returns 45.67 seconds

#### Scenario: Extract player state from MEDIA_STATUS
**Given** Chromecast sent a MEDIA_STATUS with `playerState: "PAUSED"`
**When** ChromecastPlayer `isPaused()` is called
**Then** it returns `true`

#### Scenario: Extract duration from MEDIA_STATUS
**Given** Chromecast sent a MEDIA_STATUS with `duration: 3600.0`
**When** ChromecastPlayer `getDuration()` is called
**Then** it returns 3600.0 seconds

### Requirement: ChromecastPlayer SHALL send playback control commands

ChromecastPlayer SHALL send Cast V2 protocol commands to control playback on the Chromecast device.

**Related**: player-protocol

#### Scenario: Send pause command
**Given** ChromecastPlayer is connected to a Chromecast
**When** `pause()` is called
**Then** it sends a PAUSE command via CastV2Client
**And** waits for confirmation

#### Scenario: Send play command
**Given** ChromecastPlayer is connected to a paused Chromecast
**When** `resume()` is called
**Then** it sends a PLAY command via CastV2Client
**And** waits for confirmation

#### Scenario: Send seek command
**Given** ChromecastPlayer is connected to a Chromecast
**When** `seek(to: 200.0)` is called
**Then** it sends a SEEK command with `currentTime: 200.0` via CastV2Client

### Requirement: ChromecastPlayer SHALL handle unavailable status

ChromecastPlayer SHALL throw descriptive errors when MEDIA_STATUS is not available or stale.

**Related**: player-protocol

#### Scenario: Handle missing status
**Given** ChromecastPlayer has not received any MEDIA_STATUS yet
**When** `getPosition()` is called
**Then** it throws `PlayerError.statusUnavailable`

#### Scenario: Handle stale status during buffering
**Given** ChromecastPlayer received MEDIA_STATUS 5 seconds ago with `playerState: "BUFFERING"`
**When** `getPosition()` is called
**Then** it returns the last known position
**Or** throws an error if status is too stale (>10 seconds old)

### Requirement: CastV2Client SHALL expose MediaStatus

CastV2Client SHALL be enhanced to parse and expose MediaStatus data from MEDIA_STATUS messages.

#### Scenario: Parse MediaStatus from JSON
**Given** CastV2Client receives a MEDIA_STATUS message
**When** the message contains `status: [{ currentTime, playerState, duration }]`
**Then** CastV2Client parses it into a MediaStatus struct
**And** exposes it via `var latestMediaStatus: MediaStatus?` property

#### Scenario: Update MediaStatus on new messages
**Given** CastV2Client has a MediaStatus with `currentTime: 10.0`
**When** a new MEDIA_STATUS arrives with `currentTime: 15.0`
**Then** `latestMediaStatus` is updated to reflect 15.0

### Requirement: ChromecastPlayer SHALL use position extrapolation between MEDIA_STATUS updates

ChromecastPlayer SHALL implement position extrapolation between MEDIA_STATUS messages to provide smooth UI updates, following VLC's pattern of polling every 4 seconds.

**Related**: player-protocol, VLC Chromecast implementation

#### Scenario: Extrapolate position between MEDIA_STATUS messages
**Given** ChromecastPlayer received MEDIA_STATUS at time T0 with `currentTime: 45.0`
**And** current time is T0 + 2.0 seconds
**And** player state is PLAYING
**When** `getPosition()` is called before next MEDIA_STATUS
**Then** it returns extrapolated position (47.0 seconds)
**And** extrapolation uses: lastDeviceTime + (now - lastStatusTime)

#### Scenario: Pause extrapolation when paused
**Given** ChromecastPlayer received MEDIA_STATUS with `playerState: PAUSED`
**When** `getPosition()` is called
**Then** it returns last known position without extrapolation
**And** time does not advance while paused

#### Scenario: Request status updates periodically
**Given** ChromecastPlayer is in PLAYING state
**When** more than 4 seconds have elapsed since last MEDIA_STATUS
**Then** it sends GET_STATUS command to Chromecast
**And** refreshes position baseline when response arrives
