# video-preview Specification

## Purpose
TBD - created by archiving change add-seekable-preview. Update Purpose after archive.
## Requirements
### Requirement: Local Preview Playback

The system SHALL play the original video file locally with full playback controls.

#### Scenario: Drop video for preview
- **GIVEN** the app is running with no video loaded
- **WHEN** the user drops a video file onto the drop zone
- **THEN** the video plays in the preview area using AVPlayer
- **AND** the video plays from the original file (not transcoded)
- **AND** playback controls are displayed

#### Scenario: Seek in local preview
- **GIVEN** a video is playing in local preview
- **WHEN** the user drags the seek bar to a new position
- **THEN** playback jumps to that position instantly
- **AND** the time display updates to show the new position

### Requirement: Playback Controls UI

The system SHALL display playback controls including seek bar, time display, and play/pause button.

#### Scenario: Time display
- **GIVEN** a video is loaded
- **THEN** the UI displays current time in `HH:MM:SS` or `MM:SS` format
- **AND** the UI displays total duration
- **AND** the UI displays time remaining with a minus sign (e.g., `-00:51:15`)

#### Scenario: Seek bar interaction
- **GIVEN** a video is playing
- **WHEN** the user drags the seek bar
- **THEN** the seek bar thumb follows the user's drag
- **AND** when released, playback seeks to that position

#### Scenario: Play/Pause toggle
- **GIVEN** a video is loaded
- **WHEN** the user clicks the play/pause button
- **THEN** playback toggles between playing and paused
- **AND** the button icon updates to reflect the current state

### Requirement: Chromecast Seek Support

The system SHALL support seeking during Chromecast playback by restarting FFmpeg at the requested position.

#### Scenario: Seek during Chromecast playback
- **GIVEN** a video is casting to Chromecast
- **WHEN** the user seeks to a new position
- **THEN** the system kills the current FFmpeg process
- **AND** starts a new FFmpeg process with `-ss <time>` to seek
- **AND** the Chromecast resumes playback from the new position
- **AND** seek completes within 1-2 seconds

#### Scenario: Pause during Chromecast playback
- **GIVEN** a video is casting to Chromecast
- **WHEN** the user clicks pause
- **THEN** the system sends SIGSTOP to the FFmpeg process
- **AND** Chromecast playback pauses

#### Scenario: Resume during Chromecast playback
- **GIVEN** Chromecast playback is paused
- **WHEN** the user clicks play
- **THEN** the system sends SIGCONT to the FFmpeg process
- **AND** Chromecast playback resumes from the paused position

### Requirement: Position Tracking

The system SHALL track and display the current playback position in real-time.

#### Scenario: Local preview position tracking
- **GIVEN** a video is playing in local preview
- **THEN** the current time updates continuously as playback progresses
- **AND** the seek bar position updates to reflect current progress

#### Scenario: Chromecast position tracking
- **GIVEN** a video is casting to Chromecast
- **THEN** the current time updates based on Chromecast media status
- **AND** the seek bar position reflects Chromecast playback progress

