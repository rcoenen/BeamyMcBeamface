## ADDED Requirements
### Requirement: Stream-based playback position
The system SHALL derive `currentPosition` from MPEG-TS PTS values observed on the outgoing stream, rather than FFmpeg `-progress` output.

#### Scenario: TUI reflects stream timestamps
- **WHEN** the transcoder is streaming media and the TUI displays playback time
- **THEN** the displayed time reflects the latest PTS observed on the outgoing stream
- **AND** time advances monotonically while packets are emitted

### Requirement: Seek resets the time baseline
The system SHALL reset `currentPosition` to the new seek position once the transcoder restarts streaming after a seek.

#### Scenario: Seek updates time immediately
- **WHEN** the user seeks to a new time and the transcoder restarts
- **THEN** `currentPosition` is updated to the new PTS baseline for the stream
- **AND** the TUI reflects the new time
