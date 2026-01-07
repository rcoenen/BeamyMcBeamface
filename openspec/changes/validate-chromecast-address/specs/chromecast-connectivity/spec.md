# Spec Delta: chromecast-connectivity

## ADDED Requirements

### Requirement: Address validation before connection

The system MUST validate that the Chromecast device has a non-empty IP address before attempting to establish a TLS connection.

#### Scenario: Device with empty address
- **Given** a ChromecastDevice with `address = ""`
- **When** `CastV2Client.connect()` is called
- **Then** the method throws `CastV2Error.invalidAddress`
- **And** the error message is "Device address not resolved. Please re-select the device."

#### Scenario: Device with valid address
- **Given** a ChromecastDevice with `address = "192.168.1.100"`
- **When** `CastV2Client.connect()` is called
- **Then** the method proceeds to establish TLS connection

### Requirement: Automatic re-discovery on invalid address

The system MUST trigger device re-discovery when attempting to use a device with an invalid address.

#### Scenario: Promo display with invalid address
- **Given** `selectedDevice` has empty address
- **When** `showPromoOnChromecast()` is called
- **Then** `discoverDevices()` is triggered
- **And** status message shows "Re-discovering device..."
- **And** if device is found with valid address, promo is displayed

#### Scenario: Video cast with invalid address
- **Given** `selectedDevice` has empty address
- **When** `launchChromecast()` is called
- **Then** a clear error is shown to the user
- **And** the error suggests re-selecting the device

## MODIFIED Requirements

### Requirement: Error reporting (existing)

The system MUST provide specific, actionable error messages for address resolution failures.

#### Scenario: Invalid address error display
- **Given** a `CastV2Error.invalidAddress` is thrown
- **When** the error is displayed to the user
- **Then** the message should be actionable (e.g., "Re-select device" or "Check network")
- **And** the error should not be cryptic "error 2" or "notConnected"
