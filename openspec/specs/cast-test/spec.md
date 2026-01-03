# cast-test Specification

## Purpose
TBD - created by archiving change add-cast-test. Update Purpose after archive.
## Requirements
### Requirement: Cast Test Image
The system SHALL provide a `cast-test` command that displays a test image on a Chromecast device for testing connectivity.

#### Scenario: Cast test image to first available device
- **WHEN** user runs `beamster cast-test`
- **THEN** the system discovers video-capable Chromecast devices
- **AND** starts a local HTTP server to serve the test image
- **AND** displays the Beamy McBeamface test image on the first found device
- **AND** keeps running until user presses Ctrl+C

#### Scenario: Cast test image to specific device
- **WHEN** user runs `beamster cast-test --device "Bedroom TV"`
- **THEN** the system connects to the specified device by name
- **AND** displays the test image on that device

#### Scenario: No video-capable devices found
- **WHEN** user runs `beamster cast-test`
- **AND** no video-capable Chromecast devices are found on the network
- **THEN** the system displays an error message explaining no compatible devices were found

