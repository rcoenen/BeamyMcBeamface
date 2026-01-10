# Capability: Roku Casting

Enables casting video to Roku devices using the External Control Protocol (ECP).

## ADDED Requirements

### Requirement: Roku Device Discovery

The system SHALL discover Roku devices on the local network using SSDP.

#### Scenario: Roku device found
- **WHEN** the user opens the device selector
- **AND** a Roku device is on the local network
- **THEN** the device appears in the Roku section
- **AND** the device name and model are displayed

#### Scenario: No Roku devices
- **WHEN** the user opens the device selector
- **AND** no Roku devices are on the network
- **THEN** the Roku section shows "No devices found"

### Requirement: Video Casting

The system SHALL cast HLS video URLs to Roku devices using the PlayOnRoku endpoint.

#### Scenario: Cast video to Roku
- **GIVEN** a Roku device is selected
- **WHEN** the user starts playback
- **THEN** the TranscodeServer HLS URL is sent to the Roku
- **AND** video plays on the Roku device

#### Scenario: Cast fails
- **WHEN** the Roku device rejects the video URL
- **THEN** an error message is displayed
- **AND** local playback remains available

### Requirement: Playback Controls

The system SHALL send playback commands to Roku via ECP keypress API.

#### Scenario: Pause playback
- **GIVEN** video is playing on Roku
- **WHEN** the user presses pause
- **THEN** a Play keypress is sent to Roku
- **AND** playback pauses on the device

#### Scenario: Stop playback
- **GIVEN** video is playing on Roku
- **WHEN** the user stops playback
- **THEN** a Back keypress is sent to Roku
- **AND** the Roku exits the video player
