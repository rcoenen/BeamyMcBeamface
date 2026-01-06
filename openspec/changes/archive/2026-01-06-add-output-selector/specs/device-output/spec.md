# Spec: Device Output Selection

## ADDED Requirements

### Requirement: TermKit UI SHALL provide an output selector
The TermKit TUI SHALL display an “Output” selector with options for mpv and Chromecast, prior to launching any player.

#### Scenario: Show output choices before playback
**Given** the TermKit UI has initialized  
**When** the screen renders  
**Then** it shows an output selector with at least “mpv” and “Chromecast” options  
**And** no player process is launched yet

### Requirement: Player launch SHALL be deferred until Play is pressed
The UI SHALL delay launching any player until the user presses Play/Space/Enter for the first time.

#### Scenario: First Play triggers player launch
**Given** no player has been launched yet  
**And** the user has selected an output  
**When** the user presses Play/Space/Enter  
**Then** the chosen player is launched  
**And** playback begins from the current (or last known) position

### Requirement: Switching outputs SHALL stop the previous player
When the user switches the output selection, the system SHALL stop/cleanup the currently active player before launching the new one.

#### Scenario: Switch from mpv to Chromecast
**Given** mpv is currently playing  
**When** the user selects Chromecast output and presses Play  
**Then** mpv is quit/cleaned up  
**And** Chromecast is launched and begins playback

#### Scenario: Switch from Chromecast to mpv
**Given** Chromecast is currently playing  
**When** the user selects mpv output and presses Play  
**Then** Chromecast is disconnected/cleaned up  
**And** mpv is launched and begins playback

### Requirement: Chromecast selection SHALL use TOML preference or discovery
When Chromecast is selected, the system SHALL look up a preferred device in the TOML config; if missing or unavailable, it SHALL present a discovery modal to select a device, then save it to TOML.

#### Scenario: Use configured Chromecast
**Given** a Chromecast device is configured in TOML  
**And** the device responds/available  
**When** the user presses Play with Chromecast selected  
**Then** the system connects to that device and starts playback

#### Scenario: Discovery modal when no device configured or available
**Given** Chromecast output is selected  
**And** either no device is configured, or the configured device is unavailable  
**When** the user presses Play  
**Then** the UI shows a modal listing discovered Chromecast devices  
**And** the user can select a device or cancel

#### Scenario: Save selected Chromecast
**Given** the user selected a device from discovery  
**When** selection is confirmed  
**Then** the chosen device is saved to the TOML config as the preferred device  
**And** the system proceeds to connect and play

### Requirement: Output switching SHOULD resume from last known position/state
On output switch, the new player SHOULD start from the last known playback position and pause/play state when available.

#### Scenario: Resume position on output switch
**Given** playback was at time T before switching outputs  
**When** the new output is launched  
**Then** playback starts near time T (or as close as supported)  
**And** retains the prior pause/play state if possible

### Requirement: Errors SHALL be surfaced without crashing
Failures to launch/connect/discover SHALL be shown in the UI status, keeping the session paused.

#### Scenario: Chromecast discovery finds no devices
**Given** Chromecast output is selected  
**And** discovery returns no devices  
**When** the modal closes  
**Then** the UI shows a “no devices found” status  
**And** playback remains paused until a device becomes available or another output is chosen
