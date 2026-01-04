## ADDED Requirements

### Requirement: Player Protocol Interface
The system SHALL expose a `Player` protocol with methods `getPosition()`, `getDuration()`, `isPaused()`, `pause()`, `resume()`, `seek(to:)`, and `reload(url:)`, using seconds for all time values and throwing `PlayerError` on failure. Commands SHALL return after the underlying backend accepts the instruction (dispatch-level sync) without waiting for playback to settle, and implementations SHALL be safe for serial use from the TUI thread. The Player SHALL be the sole source of truth for playback state presented to the user.

#### Scenario: Query playback position
- **WHEN** TranscoderTUI calls `player.getPosition()`
- **THEN** the player returns the current playback position in seconds relative to the start of the active stream
- **AND** throws `PlayerError.statusUnavailable` if it cannot determine a position
- **AND** TranscoderTUI MAY cache and display the last-known position if the query fails

#### Scenario: Dispatch pause/resume/seek
- **WHEN** TranscoderTUI invokes `pause()`, `resume()`, or `seek(to:)`
- **THEN** the player sends the corresponding command to its backend before returning
- **AND** throws `PlayerError.commandFailed` if the backend rejects or cannot dispatch the command

#### Scenario: Serial UI thread usage
- **WHEN** player methods are invoked sequentially from the TUI’s main runloop
- **THEN** no additional synchronization is required by the caller
- **AND** player implementations process calls without race conditions introduced by the abstraction

### Requirement: Player Error Normalization
The system SHALL provide a `PlayerError` enum to normalize backend failures, including at minimum: `statusUnavailable`, `unsupportedOperation`, `commandFailed`, and `disconnected`.

#### Scenario: Unsupported reload operation
- **WHEN** TranscoderTUI calls `player.reload(url:)` on a backend that cannot reload streams (e.g., server-backed player)
- **THEN** the player throws `PlayerError.unsupportedOperation`

#### Scenario: Missing status
- **WHEN** the player cannot read state from its backend (e.g., no Chromecast MEDIA_STATUS received)
- **THEN** it throws `PlayerError.statusUnavailable`

#### Scenario: Connection loss surfaced
- **WHEN** the underlying backend disconnects or drops its session
- **THEN** the next player command or query throws `PlayerError.disconnected`

### Requirement: Player Lifecycle Ownership
Player instances SHALL be constructed with already-initialized backends (e.g., connected mpv controller, active CastV2Client session, running TranscodeServer) and SHALL NOT implicitly start or tear down those backends. Reload semantics SHALL match backend capabilities: mpv reloads the stream, Chromecast loads the new stream on the active session, and server reload is unsupported.

#### Scenario: Mpv lifecycle responsibility
- **WHEN** TranscoderTUI constructs an MpvPlayer
- **THEN** it provides an already-launched `MpvController` and remains responsible for launching and terminating mpv
- **AND** MpvPlayer only sends playback commands and reload requests

#### Scenario: Chromecast lifecycle responsibility
- **WHEN** TranscoderTUI constructs a ChromecastPlayer
- **THEN** it provides a connected `CastV2Client` with an active media session
- **AND** ChromecastPlayer issues SEEK/PLAY/PAUSE against that session
- **AND** `reload(url:)` loads the provided stream into the current session without creating a new client connection

#### Scenario: Server lifecycle responsibility
- **WHEN** TranscoderTUI constructs a ServerPlayer
- **THEN** it reuses an already-running `TranscodeServer`
- **AND** `reload(url:)` throws `PlayerError.unsupportedOperation` instead of restarting the server

### Requirement: Chromecast Media Status Tracking
The system SHALL parse Chromecast `MEDIA_STATUS` messages into a `MediaStatus` value containing `currentTime` (seconds), `duration` (seconds), `playerState` (`PLAYING`, `PAUSED`, `BUFFERING`, `IDLE`), and `mediaSessionId`, and SHALL expose the latest value via `CastV2Client.latestMediaStatus`. ChromecastPlayer SHALL ignore stale status messages whose `mediaSessionId` does not match the current session and MAY surface idle reasons for diagnostics.

#### Scenario: Update media status on message
- **WHEN** CastV2Client receives a `MEDIA_STATUS` payload with a status entry
- **THEN** it updates `latestMediaStatus` with the parsed values for the current session
- **AND** makes them available for ChromecastPlayer queries

#### Scenario: Status required for queries
- **WHEN** ChromecastPlayer is queried for position or duration before any `MEDIA_STATUS` has been received
- **THEN** it throws `PlayerError.statusUnavailable`

#### Scenario: Replace status on new session
- **WHEN** CastV2Client receives a `MEDIA_STATUS` message with a `mediaSessionId` different from the current one
- **THEN** it replaces `latestMediaStatus` with the new session values

### Requirement: Device-Authoritative UI State
TranscoderTUI SHALL display playback position and pause/play state exclusively from the injected `Player` (device), caching last-known values when queries fail, and SHALL NOT fall back to `TranscodeServer` state for UI rendering. Server interactions are command-only (pause/resume/seek/reload) and SHALL NOT override displayed state.

#### Scenario: Successful player query
- **WHEN** TranscoderTUI requests playback position or pause state
- **THEN** it queries the injected player
- **AND** displays the returned values

#### Scenario: Player unavailable fallback
- **WHEN** a player method throws a `PlayerError`
- **THEN** TranscoderTUI displays the last-known device state (or an unknown indicator) instead of server state
- **AND** continues running without crashing

#### Scenario: Command failure handling
- **WHEN** a player command (pause, resume, seek, reload) throws
- **THEN** TranscoderTUI retains the previous UI state and continues running, allowing subsequent commands once the backend is available again
