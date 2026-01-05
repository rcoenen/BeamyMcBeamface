# Spec: Chromecast Configuration Synchronization

## MODIFIED Requirements

### Requirement: TermKit UI SHALL separate runtime output state from Chromecast device configuration

The TermKit UI SHALL maintain `selectedOutput` (which player is currently active) independently from `selectedChromecastName` (which Chromecast device is configured as preferred). Switching runtime output to mpv SHALL NOT clear the configured Chromecast device.

**Related**: device-output

#### Scenario: Switch to mpv preserves configured Chromecast
**Given** `selectedOutput = .chromecast` and `selectedChromecastName = "Bedroom TV"`
**When** user clicks the mpv radio button
**Then** `selectedOutput` changes to `.mpv`
**And** `selectedChromecastName` remains `"Bedroom TV"`
**And** RadioGroup label still shows `"Chromecast (Bedroom TV)"`
**And** TOML `config.chromecast.defaultDevice` remains `"Bedroom TV"`

#### Scenario: Switch back to Chromecast uses preserved configuration
**Given** `selectedOutput = .mpv` and `selectedChromecastName = "Bedroom TV"`
**When** user clicks the Chromecast radio button
**Then** `selectedOutput` changes to `.chromecast`
**And** playback launches to "Bedroom TV" device
**And** no device selection modal appears (uses preserved config)

#### Scenario: Boot with configured device seeds in-memory state
**Given** TOML has `config.chromecast.defaultDevice = "Bedroom TV"`
**When** TermKit UI initializes
**Then** `selectedChromecastName` is set to `"Bedroom TV"`
**And** RadioGroup shows `"Chromecast (Bedroom TV)"`
**And** no network discovery is performed (optimistic load)

### Requirement: Discovery modal checkmark SHALL reflect configured device, not runtime output

The discovery modal's checkmark (✓) SHALL indicate which Chromecast device is configured in `selectedChromecastName`, independent of which output is currently playing. The checkmark indicates configuration, not playback status.

**Related**: device-output

#### Scenario: Modal shows checkmark on configured device while playing via mpv
**Given** `selectedOutput = .mpv` and `selectedChromecastName = "Bedroom TV"`
**When** user clicks "Select Chromecast..." button
**Then** discovery modal opens
**And** checkmark (✓) appears on "Bedroom TV"
**And** "None" does NOT have a checkmark

#### Scenario: Modal shows checkmark on None when no device configured
**Given** `selectedChromecastName = nil`
**When** user clicks "Select Chromecast..." button
**Then** discovery modal opens
**And** checkmark (✓) appears on "🚫 None (disable Chromecast)"
**And** no device has a checkmark

#### Scenario: Modal pre-selects configured device in list
**Given** `selectedChromecastName = "Living Room TV"`
**When** discovery modal opens
**Then** ListView's `selectedItem` index points to "Living Room TV"
**And** list scrolls to show the selected item

### Requirement: TermKit UI SHALL synchronize three state representations on every change

Changes to Chromecast device configuration SHALL update three synchronized representations: `selectedChromecastName` (in-memory), RadioGroup label (visual), and TOML `config.chromecast.defaultDevice` (persistent).

**Related**: device-output

#### Scenario: Selecting device in modal updates all three representations
**Given** `selectedChromecastName = nil`
**When** user selects "Bedroom TV" in discovery modal and clicks OK
**Then** `selectedChromecastName` is set to `"Bedroom TV"`
**And** RadioGroup label updates to `"Chromecast (Bedroom TV)"`
**And** TOML `config.chromecast.defaultDevice` is set to `"Bedroom TV"`
**And** `config.save()` is called to persist to disk

#### Scenario: Selecting None in modal clears all three representations
**Given** `selectedChromecastName = "Bedroom TV"`
**When** user selects "🚫 None" in discovery modal and clicks OK
**Then** `selectedChromecastName` is set to `nil`
**And** RadioGroup label updates to `"Chromecast (none)"`
**And** TOML `config.chromecast.defaultDevice` is cleared (nil or removed)
**And** `selectedOutput` is forced to `.mpv`
**And** `config.save()` is called to persist to disk

#### Scenario: Canceling modal preserves all three representations
**Given** `selectedChromecastName = "Bedroom TV"`
**When** user opens discovery modal, selects a different device, and clicks Cancel
**Then** `selectedChromecastName` remains `"Bedroom TV"`
**And** RadioGroup label remains `"Chromecast (Bedroom TV)"`
**And** TOML `config.chromecast.defaultDevice` remains `"Bedroom TV"`

## ADDED Requirements

### Requirement: Discovery modal SHALL validate configured device against discovered devices

When the discovery modal opens, the system SHALL verify that the configured device (`selectedChromecastName`) exists in the list of discovered devices. If not found, the system SHALL automatically clear the configuration and select "None" in the modal.

**Related**: device-output

#### Scenario: Configured device not found during discovery
**Given** TOML has `config.chromecast.defaultDevice = "Bedroom TV"`
**And** `selectedChromecastName = "Bedroom TV"`
**When** discovery modal opens
**And** discovery finds devices `["Living Room TV", "Kitchen TV"]` (Bedroom TV not found)
**Then** `selectedChromecastName` is cleared to `nil`
**And** RadioGroup label updates to `"Chromecast (none)"`
**And** TOML `config.chromecast.defaultDevice` is cleared
**And** `config.save()` is called
**And** modal shows checkmark (✓) on "🚫 None"
**And** log message: "Configured device 'Bedroom TV' not found - clearing configuration"

#### Scenario: Configured device found during discovery
**Given** `selectedChromecastName = "Bedroom TV"`
**When** discovery modal opens
**And** discovery finds devices `["Bedroom TV", "Living Room TV"]`
**Then** `selectedChromecastName` remains `"Bedroom TV"`
**And** modal shows checkmark (✓) on "Bedroom TV"
**And** no auto-correction occurs

#### Scenario: No devices found during discovery with configured device
**Given** `selectedChromecastName = "Bedroom TV"`
**When** discovery modal opens
**And** discovery finds 0 devices
**Then** `selectedChromecastName` is cleared to `nil`
**And** RadioGroup label updates to `"Chromecast (none)"`
**And** modal shows only "🚫 None" with checkmark (✓)

### Requirement: TermKit UI SHALL prevent selecting Chromecast radio when no device configured

When `selectedChromecastName` is `nil` (no Chromecast configured), attempting to select the Chromecast radio button SHALL automatically open the "Select Chromecast..." modal to force device selection.

**Related**: device-output

#### Scenario: Auto-open modal when selecting Chromecast (none)
**Given** `selectedChromecastName = nil`
**And** RadioGroup shows `"○ Chromecast (none)"`
**When** user clicks the Chromecast radio button
**Then** the "Select Chromecast..." modal opens immediately
**And** user must select a device or cancel
**And** if user cancels, `selectedOutput` reverts to `.mpv`

#### Scenario: Direct playback when device already configured
**Given** `selectedChromecastName = "Bedroom TV"`
**And** `selectedOutput = .mpv`
**When** user clicks the Chromecast radio button
**Then** `selectedOutput` changes to `.chromecast`
**And** playback launches to "Bedroom TV" immediately
**And** no modal appears

## REMOVED Requirements

None - this change only fixes bugs in existing requirements.
