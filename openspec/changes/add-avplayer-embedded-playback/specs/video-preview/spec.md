## MODIFIED Requirements

### Requirement: Local Preview Playback

The system SHALL start the transcoder on file drop and play its streamed output internally with full playback controls.

#### Scenario: Drop video for preview
- **GIVEN** the app is running with no video loaded
- **WHEN** the user drops a video file onto the drop zone
- **THEN** the transcoder starts for that file
- **AND** the embedded player loads the transcoder stream URL
- **AND** playback starts in the preview area with controls shown

#### Scenario: Seek in local preview
- **GIVEN** a video is playing in local preview
- **WHEN** the user drags the seek bar to a new position
- **THEN** playback jumps to that position within 1 second
- **AND** the time display updates to show the new position

## ADDED Requirements

### Requirement: Output switching SHALL start transcoder on demand

The system SHALL start the FFmpeg-based `TranscodeServer` on demand when switching from local preview to Chromecast, preserving playback position.

#### Scenario: Switch from local preview to Chromecast
- **GIVEN** a video is playing in local preview at position 01:30
- **WHEN** the user switches output to Chromecast
- **THEN** the app starts `TranscodeServer` (if not running) and seeks it to 01:30
- **AND** the embedded player and Chromecast both use the transcoder stream URL
- **AND** Chromecast begins playback at 01:30 (±2s)
