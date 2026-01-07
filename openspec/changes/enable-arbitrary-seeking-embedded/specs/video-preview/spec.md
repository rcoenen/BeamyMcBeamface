## MODIFIED Requirements

### Requirement: Seek in local preview

The system SHALL support arbitrary seeking to any position in the embedded HLS WebView player by restarting FFmpeg at the target position and reloading the WebView with a cache-busted URL.

#### Scenario: Instant seek within transcoded range
- **GIVEN** a video is playing in embedded mode
- **AND** the video has been transcoded up to 10:00
- **WHEN** the user seeks to 5:00 (within transcoded range)
- **THEN** playback jumps to 5:00 instantly (via `video.currentTime` JavaScript)
- **AND** the time display updates to show 5:00
- **AND** no FFmpeg restart occurs

#### Scenario: Arbitrary seek beyond transcoded range
- **GIVEN** a video is playing in embedded mode at 5:00
- **AND** the video has been transcoded up to 10:00
- **WHEN** the user seeks to 30:00 (beyond transcoded range)
- **THEN** the system kills the current FFmpeg process
- **AND** starts a new FFmpeg process with `-ss 1800` (30:00)
- **AND** displays "Seeking..." status message
- **AND** waits for the new HLS playlist to become available (polling up to 30 seconds)
- **AND** reloads the WebView with a cache-busted URL (e.g., `stream.m3u8?t=1736188567.123`)
- **AND** playback resumes at 30:00 within 2-5 seconds
- **AND** the time display updates to show 30:00
- **AND** status message changes to "Playing"

#### Scenario: Seek during pause
- **GIVEN** a video is paused in embedded mode
- **WHEN** the user seeks to any position (within or beyond transcoded range)
- **THEN** the seek completes successfully
- **AND** the video remains paused at the new position
- **AND** playback can be resumed from the new position

#### Scenario: Rapid successive seeks
- **GIVEN** a video is playing in embedded mode
- **WHEN** the user rapidly drags the seek bar multiple times
- **THEN** only the final seek position is processed
- **AND** intermediate seek positions are ignored (debounced)
- **AND** FFmpeg restarts only once for the final position

#### Scenario: Stream poll timeout
- **GIVEN** a video is playing in embedded mode
- **WHEN** the user seeks to a new position
- **AND** the new HLS stream does not become available within 30 seconds
- **THEN** the system displays "Seek failed - stream not ready" error
- **AND** playback remains at the previous position
- **AND** the user can retry the seek operation

## ADDED Requirements

### Requirement: Cache-busted URL reloading

The system SHALL reload the WebView with a cache-busted URL parameter when restarting FFmpeg to ensure Safari treats the reloaded stream as a new resource.

#### Scenario: Cache-bust parameter appended
- **GIVEN** the transcoder stream URL is `http://192.168.1.100:8080/stream.m3u8`
- **WHEN** the system performs an arbitrary seek requiring FFmpeg restart
- **THEN** the WebView is reloaded with URL `http://192.168.1.100:8080/stream.m3u8?t=<timestamp>`
- **AND** the timestamp is unique for each seek operation
- **AND** the HTTP server ignores the query parameter and serves the playlist normally

#### Scenario: No cache confusion
- **GIVEN** Safari has loaded and cached segments from a previous FFmpeg process
- **WHEN** FFmpeg is restarted at a new position with different segment numbering
- **AND** the WebView is reloaded with a cache-busted URL
- **THEN** Safari fetches the new playlist as a fresh resource
- **AND** Safari does not request old segment numbers from the previous process
- **AND** playback proceeds without `:4` errors or segment 404s

### Requirement: Unified seeking behavior

The system SHALL provide consistent arbitrary seeking behavior between embedded and Chromecast playback modes.

#### Scenario: Embedded arbitrary seek matches Chromecast behavior
- **GIVEN** a video can be played in both embedded and Chromecast modes
- **WHEN** the user seeks to an arbitrary position beyond transcoded range in embedded mode
- **THEN** the seek completes successfully within 2-5 seconds (same as Chromecast)
- **AND** the seek uses the same FFmpeg restart approach as Chromecast
- **AND** the user experience is consistent between output modes

#### Scenario: Status feedback during seek
- **GIVEN** the user initiates an arbitrary seek in embedded mode
- **WHEN** FFmpeg is restarting and the new stream is not yet ready
- **THEN** the status message displays "Seeking..."
- **AND** when playback resumes, the status message changes to "Playing"
- **AND** the user understands that a brief delay is expected
