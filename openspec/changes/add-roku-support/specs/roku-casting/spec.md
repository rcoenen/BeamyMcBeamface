# Capability: Roku Casting

Enables casting video to Roku devices using the External Control Protocol (ECP).

## ADDED Requirements

### Requirement: Roku Device Discovery & Picker UX

The system SHALL discover Roku devices on the local network using SSDP and present them in a Roku section of the device picker with clear states and guidance.

#### Scenario: Discovery states
- **WHEN** the user opens the device selector
- **THEN** the Roku section shows "Scanning for Roku devices…" while discovery runs (3–5s), with a Refresh action available

#### Scenario: Roku device found
- **WHEN** a Roku device is discovered
- **THEN** it appears under the Roku section with name and model (e.g., "Living Room Roku • Model 3840")
- **AND** selecting it highlights the choice

#### Scenario: No Roku devices
- **WHEN** discovery completes and no Roku devices are found
- **THEN** the Roku section shows "No Roku devices found. Confirm laptop and Roku are on the same Wi‑Fi and powered on."

#### Scenario: Prereq hint
- **WHEN** the Roku section is shown
- **THEN** a one-line hint is visible: "Laptop and Roku must be on the same Wi‑Fi."

### Requirement: Video Casting

The system SHALL cast HLS video URLs to Roku devices using the receiver channel (PlayOnRoku or configured alternative) and guide the user through casting with clear feedback.

#### Scenario: Cast video to Roku
- **GIVEN** a Roku device is selected in the picker
- **WHEN** the user clicks "Cast to Roku"
- **THEN** the TranscodeServer HLS URL is sent to the Roku via the configured receiver endpoint
- **AND** a status appears: "Casting to <device name>…" followed by "Now playing on <device name>" once Roku confirms launch

#### Scenario: Cast fails
- **WHEN** the Roku device rejects the video URL or the request fails
- **THEN** a user-visible error is shown: "Couldn't start playback on Roku. Try again or play locally."
- **AND** local playback remains available and in control
- **AND** a Retry action is offered

#### Scenario: Receiver/channel prerequisite
- **WHEN** casting requires a specific Roku channel (e.g., Web Video Caster or PlayOnRoku)
- **AND** it is not installed or fails to launch
- **THEN** prompt the user: "Install <channel name> on your Roku to play external URLs," with a link to instructions

### Requirement: Playback Controls

The system SHALL send playback commands to Roku via ECP keypress API with controls labeled for Roku control.

#### Scenario: Pause/Play toggle
- **GIVEN** video is playing on Roku
- **WHEN** the user presses the "Pause/Play on Roku" control
- **THEN** a Play keypress is sent to Roku (toggle pause/resume)
- **AND** the UI reflects the toggled state

#### Scenario: Stop playback
- **GIVEN** video is playing on Roku
- **WHEN** the user presses "Stop on Roku (exit player)"
- **THEN** a Back keypress is sent to Roku
- **AND** the Roku exits the video player
