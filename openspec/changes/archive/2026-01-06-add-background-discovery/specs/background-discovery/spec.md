# Spec: Background Chromecast Discovery

## ADDED Requirements

### Requirement: TermKit UI SHALL trigger Chromecast discovery on boot

The TermKit UI SHALL start Chromecast device discovery in the background immediately after UI initialization, without blocking the main thread or showing a spinner.

**Related**: chromecast-config-sync

#### Scenario: Start discovery on boot
**Given** TermKit UI is initializing
**When** `run()` completes UI setup
**Then** background discovery starts on `DispatchQueue.global()`
**And** discoveryState changes from `.idle` to `.scanning(started: Date())`
**And** UI remains responsive (no blocking)
**And** no spinner is shown to the user

#### Scenario: Discovery completes successfully
**Given** background discovery is running
**When** discovery finds devices `["Bedroom TV", "Living Room TV"]`
**Then** discoveryState changes to `.completed(devices, timestamp: Date())`
**And** discovered devices are cached for later use
**And** configured device validation runs

#### Scenario: Discovery finds no devices
**Given** background discovery is running
**When** discovery completes with 0 devices
**Then** discoveryState changes to `.completed([], timestamp: Date())`
**And** configured device validation runs (will clear config)

### Requirement: TermKit UI SHALL auto-invalidate configured device when not found

When background discovery completes, the system SHALL check if the configured Chromecast device exists in the discovered devices. If not found, the system SHALL automatically clear the configuration and revert to mpv output.

**Related**: chromecast-config-sync

#### Scenario: Configured device found during boot discovery
**Given** TOML has `chromecast.defaultDevice = "Bedroom TV"`
**And** background discovery is running
**When** discovery finds devices including "Bedroom TV"
**Then** no auto-invalidation occurs
**And** UI remains showing "Chromecast (Bedroom TV)"
**And** `selectedOutput` remains unchanged

#### Scenario: Configured device NOT found during boot discovery
**Given** TOML has `chromecast.defaultDevice = "Bedroom TV"`
**And** UI shows "Chromecast (Bedroom TV)" optimistically
**When** background discovery completes with devices `["Living Room TV"]` (Bedroom TV missing)
**Then** `selectedChromecastName` is cleared to `nil`
**And** `selectedOutput` is set to `.mpv`
**And** RadioGroup label updates to "Chromecast (none)"
**And** RadioGroup selection moves to "mpv" radio button
**And** TOML `chromecast.defaultDevice` is cleared
**And** `config.save()` is called
**And** log message: "Background discovery: 'Bedroom TV' not found - auto-invalidating"

#### Scenario: No device configured on boot
**Given** TOML has no `chromecast.defaultDevice`
**When** background discovery completes
**Then** no auto-invalidation occurs (nothing to clear)
**And** UI remains showing "Chromecast (none)"

### Requirement: Discovery modal SHALL reuse cached discovery results

When the user opens the "Select Chromecast..." modal, the system SHALL check the discovery state and reuse cached results if available, rather than always running a fresh network scan.

**Related**: device-output

#### Scenario: Open modal while boot discovery still running
**Given** background discovery started at T+0s and is still running
**When** user clicks "Select Chromecast..." button at T+2s
**Then** modal opens showing spinner with message "Scanning for Chromecasts…"
**And** no new discovery is started (reuses in-flight scan)
**When** background discovery completes at T+4s
**Then** spinner is hidden
**And** discovered devices are shown in list

#### Scenario: Open modal after boot discovery completed
**Given** background discovery completed at T+3s with devices `["Bedroom TV", "Living Room TV"]`
**When** user clicks "Select Chromecast..." button at T+10s
**Then** modal opens immediately showing cached devices
**And** no spinner is shown
**And** no new network scan is triggered

#### Scenario: Open modal when no discovery has run
**Given** discoveryState is `.idle` (no discovery run yet)
**When** user clicks "Select Chromecast..." button
**Then** modal opens showing spinner
**And** new discovery is started
**When** discovery completes
**Then** devices are shown in list

### Requirement: Discovery modal SHALL provide manual rescan capability

The discovery modal SHALL include a "Rescan" button that allows the user to trigger a fresh network scan, updating the cached device list.

**Related**: device-output

#### Scenario: Rescan button triggers fresh discovery
**Given** modal is open showing cached devices from T+3s
**And** current time is T+20s
**When** user clicks "Rescan" button
**Then** discoveryState changes to `.scanning(started: Date())`
**And** spinner appears in modal
**And** new network discovery is triggered
**When** discovery completes
**Then** device list in modal updates with fresh results
**And** timestamp updates to new scan time

#### Scenario: Rescan while discovery already running
**Given** modal is open with spinner (discovery running)
**When** user clicks "Rescan" button
**Then** no new discovery is started (already scanning)
**And** current scan continues
**And** button may be disabled or show "Scanning..." state

#### Scenario: Modal shows last scan timestamp
**Given** discovery completed at T+3s
**When** user opens modal at T+15s
**Then** modal displays "Last scanned: 12s ago" or similar
**And** "Rescan" button is enabled

### Requirement: Discovery state SHALL be thread-safe

The discovery state SHALL be safely accessible from both the main thread (UI updates) and background threads (discovery completion), preventing race conditions.

**Related**: background-discovery

#### Scenario: State accessed from multiple threads
**Given** background discovery is running
**When** main thread checks discoveryState
**And** background thread completes discovery and updates state
**Then** no race condition occurs
**And** state reads are always consistent
**And** no crashes occur from concurrent access

#### Scenario: UI updates on main thread
**Given** discovery completes on background thread
**When** auto-invalidation logic updates UI
**Then** UI updates (RadioGroup, selectedOutput) happen on main thread via `DispatchQueue.main.async`
**And** TermKit views are only touched from main thread

## MODIFIED Requirements

### Requirement: Discovery modal validation SHALL use shared discovery results

The existing device validation logic in the modal SHALL use the shared discovery state instead of always running a fresh scan.

**Related**: chromecast-config-sync

#### Scenario: Validation uses cached discovery results
**Given** background discovery completed with devices `["Bedroom TV"]`
**When** modal validation runs
**Then** validation uses cached devices from discoveryState
**And** no duplicate network scan is triggered

## REMOVED Requirements

None - this change only adds new functionality.
