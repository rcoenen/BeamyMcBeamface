# macOS UI Specification

The TermKit TUI is the behavioral reference for playback/output switching; the legacy macOS UI is obsolete and should not guide behavior.

## ADDED Requirements

### Requirement: macOS UI SHALL use Player protocol for playback control

The BeamyApp CastingViewModel SHALL use the existing BeamyKit Player protocol (MpvPlayer, ChromecastPlayer) instead of querying TranscodeServer directly.

#### Scenario: Playback state comes from Player
- **WHEN** video is playing
- **THEN** `isPlaying` queries `player?.isPaused()`
- **AND** `currentTime` queries `player?.getPosition()`
- **AND** controls call `player?.pause()`, `player?.resume()`, `player?.seek()`

### Requirement: macOS UI SHALL provide output selector

The ContentView SHALL display a segmented control allowing users to choose between "mpv" (local) and "Chromecast" outputs.

#### Scenario: User switches from Chromecast to mpv
- **GIVEN** video playing via Chromecast at 45s
- **WHEN** user selects "mpv" segment
- **THEN** `viewModel.switchOutput(to: .mpv)` is called
- **AND** position is preserved (mpv starts at ~45s)
- **AND** pause state is preserved

### Requirement: Chromecast device selection SHALL use modal sheet

The macOS UI SHALL display a modal sheet for Chromecast device selection with a list of discovered devices and a rescan button.

#### Scenario: User opens device selector
- **GIVEN** output is set to Chromecast
- **WHEN** user clicks device button
- **THEN** modal sheet opens showing discovered devices
- **AND** "Rescan" button is available
- **AND** tapping a device selects it and closes modal

### Requirement: Position SHALL be polled from Player every 250ms

The CastingViewModel SHALL poll `player?.getPosition()` every 250ms to update the UI, matching TUI behavior.

#### Scenario: Timer updates position display
- **GIVEN** video is playing
- **WHEN** timer fires every 250ms
- **THEN** `player?.getPosition()` is called
- **AND** time label and progress bar update

### Requirement: Output choice SHALL persist to config

The selected output type (mpv/chromecast) and Chromecast device SHALL be saved to beamy.toml and restored on app launch.

#### Scenario: Output preference restored on launch
- **GIVEN** user previously selected "mpv" output
- **WHEN** app launches
- **THEN** Config is loaded
- **AND** output selector shows "mpv" as selected

### Requirement: Keyboard shortcuts SHALL match TUI

The macOS UI SHALL support keyboard shortcuts: Space (play/pause), Left/Right arrows (seek ±10s).

#### Scenario: Space toggles playback
- **GIVEN** video is playing
- **WHEN** user presses Space
- **THEN** `viewModel.togglePlayPause()` is called
- **AND** video pauses

### Requirement: macOS UI SHALL support drag-and-drop source selection

The macOS UI SHALL accept video files via drag-and-drop to start playback without CLI arguments.

#### Scenario: User drops a video file
- **GIVEN** the app is idle
- **WHEN** the user drags a video file onto the window
- **THEN** the file is accepted if it is a supported video type
- **AND** the view model loads media info and starts the transcoder for playback
