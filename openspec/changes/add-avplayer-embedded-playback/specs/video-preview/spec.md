## MODIFIED Requirements

### Requirement: Local Preview Playback

The system SHALL play the original video file locally with full playback controls and fall back to external mpv when AVPlayer cannot play the file.

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

#### Scenario: Unsupported format fallback to external mpv
- **GIVEN** output type is set to local preview
- **AND** the dropped file is not playable by AVPlayer (e.g., MKV)
- **WHEN** the user drops the file
- **THEN** the system launches external mpv with the file URL
- **AND** the UI shows "Playing in external window (format not supported)"

## ADDED Requirements

### Requirement: Output switching SHALL start transcoder on demand

The system SHALL start the FFmpeg-based `TranscodeServer` on demand when switching from local preview to Chromecast, preserving playback position.

#### Scenario: Switch from local preview to Chromecast
- **GIVEN** a video is playing in local preview at position 01:30
- **WHEN** the user switches output to Chromecast
- **THEN** the app starts `TranscodeServer` (if not running) and seeks it to 01:30
- **AND** AVPlayer pauses
- **AND** Chromecast begins playback at 01:30 (±2s)

