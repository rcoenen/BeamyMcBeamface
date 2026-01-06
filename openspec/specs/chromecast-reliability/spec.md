# chromecast-reliability Specification

## Purpose
TBD - created by archiving change harden-chromecast-playback. Update Purpose after archive.
## Requirements
### Requirement: CastV2Client MUST provide thread-safe access to media status

The CastV2Client SHALL synchronize access to `latestMediaStatus` to prevent race conditions when the network thread updates status while the main thread reads it.

**Related**: position-tracking

#### Scenario: Concurrent status read and write
**Given** Chromecast is playing at 30.5s
**And** network thread receives MEDIA_STATUS update with position 31.0s
**When** main thread calls `client.latestMediaStatus` during the update
**Then** main thread receives either 30.5s (old) OR 31.0s (new)
**And** main thread does NOT receive torn/partial data
**And** no crash or undefined behavior occurs

#### Scenario: Multiple threads reading status simultaneously
**Given** `latestMediaStatus` contains valid MediaStatus
**When** 3 threads call `client.latestMediaStatus` concurrently
**Then** all 3 threads receive the same consistent MediaStatus value
**And** no data corruption occurs

### Requirement: Media commands MUST complete asynchronously without blocking

The CastV2Client SHALL execute loadMedia() and sendMediaCommand() asynchronously, returning control to the caller immediately and invoking a completion handler when the operation finishes.

**Related**: chromecast-reliability

#### Scenario: Loading media does not block UI thread
**Given** TermKitTranscoderUI is running on main thread
**When** user selects Chromecast and `loadMedia()` is called
**Then** method returns within 100ms
**And** UI remains responsive during media loading
**And** completion handler is invoked when MEDIA_STATUS confirms load success

#### Scenario: Media load times out after 5 seconds
**Given** Chromecast device is slow to respond
**When** `loadMedia()` is called with 5s timeout
**And** no MEDIA_STATUS arrives within 5 seconds
**Then** completion handler is invoked with timeout error
**And** no infinite wait occurs

#### Scenario: Media command confirms execution
**Given** Chromecast is playing at 10s
**When** `sendMediaCommand(type: "SEEK", currentTime: 60.0)` is called
**And** MEDIA_STATUS update arrives with currentTime ≈ 60.0
**Then** completion handler is invoked with success
**And** command is confirmed executed

### Requirement: Blocking sleep operations SHALL be removed from command flow

The CastV2Client SHALL NOT use `Thread.sleep()` or other blocking delays during command execution or connection establishment.

**Related**: chromecast-reliability

#### Scenario: No blocking sleep after launching receiver app
**Given** CastV2Client is connecting to Chromecast
**When** `launchDefaultMediaReceiver()` is called
**Then** method completes without calling `Thread.sleep()`
**And** waits for RECEIVER_STATUS asynchronously via callback

#### Scenario: No blocking sleep after loading media
**Given** Chromecast receiver app is running
**When** `loadMedia()` is called
**Then** method completes without calling `Thread.sleep()`
**And** waits for MEDIA_STATUS asynchronously via callback

### Requirement: Player commands MUST validate successful execution

The ChromecastPlayer SHALL verify that seek(), pause(), and resume() commands were executed by the Chromecast device, logging warnings if validation fails.

**Related**: chromecast-reliability, position-tracking

#### Scenario: Seek command validation with position confirmation
**Given** Chromecast is playing at 10s
**When** `player.seek(to: 60.0)` is called
**And** MEDIA_STATUS update arrives with currentTime = 59.8s
**Then** seek is considered successful (within ±2s tolerance)
**And** no warning is logged

#### Scenario: Seek command validation timeout
**Given** Chromecast is playing at 10s
**When** `player.seek(to: 60.0)` is called
**And** no MEDIA_STATUS update arrives within 3 seconds
**Then** warning is logged: "Seek to 60.0s not confirmed within 3s"
**And** method returns (does not throw)
**And** player continues normal operation

#### Scenario: Pause command validation
**Given** Chromecast is playing
**When** `player.pause()` is called
**And** MEDIA_STATUS update arrives with playerState = "PAUSED"
**Then** pause is considered successful
**And** no warning is logged

#### Scenario: Resume command validation
**Given** Chromecast is paused
**When** `player.resume()` is called
**And** MEDIA_STATUS update arrives with playerState = "PLAYING"
**Then** resume is considered successful
**And** no warning is logged

### Requirement: Command failures MUST be retried once before failing

When a media command fails due to network error or timeout, the system SHALL retry the command once before reporting failure to the caller.

**Related**: chromecast-reliability

#### Scenario: Successful retry after network error
**Given** Chromecast connection is unstable
**When** `sendMediaCommand(type: "PAUSE")` fails with network error
**Then** system waits 500ms
**And** retries the PAUSE command once
**And** second attempt succeeds
**And** caller receives success result

#### Scenario: Failure after retry exhausted
**Given** Chromecast is disconnected
**When** `sendMediaCommand(type: "SEEK")` fails with timeout
**And** retry also fails with timeout
**Then** caller receives error result
**And** log shows: "Command SEEK failed after 2 attempts"

#### Scenario: No retry for validation failures
**Given** Chromecast responds to SEEK but doesn't reach target position
**When** validation detects position mismatch
**Then** no retry is attempted (validation failure is non-fatal)
**And** warning is logged only

