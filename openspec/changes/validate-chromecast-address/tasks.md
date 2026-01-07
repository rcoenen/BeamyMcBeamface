# Tasks: validate-chromecast-address

## Implementation Order

### 1. Add `invalidAddress` error case to `CastV2Error`
**File:** `Sources/BeamyKit/Chromecast/CastV2Client.swift`
- Add new case `invalidAddress` to `CastV2Error` enum
- Add descriptive message: "Device address not resolved. Please re-select the device."
- **Validation:** Build succeeds

### 2. Add address validation in `CastV2Client.connect()`
**File:** `Sources/BeamyKit/Chromecast/CastV2Client.swift`
- At start of `connect()`, check `device.address.isEmpty`
- If empty, throw `CastV2Error.invalidAddress`
- Log the validation failure
- **Validation:** Unit test or manual test with empty address device

### 3. Add `hasValidAddress` computed property to `ChromecastDevice`
**File:** `Sources/BeamyKit/Chromecast/ChromecastDevice.swift`
- Add `public var hasValidAddress: Bool { !address.isEmpty }`
- **Validation:** Build succeeds

### 4. Handle invalid address in `CastingViewModel.showPromoOnChromecast()`
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Before creating `CastV2Client`, check `device.hasValidAddress`
- If invalid, call `discoverDevices()` and show status "Re-discovering device..."
- After discovery completes, retry promo display if device is now valid
- **Validation:** Manual test - remove device from network, switch to Chromecast output, verify re-discovery triggers

### 5. Handle invalid address in `CastingViewModel.launchChromecast()`
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Check `device.hasValidAddress` before creating client
- If invalid, throw `PlayerError` with descriptive message
- **Validation:** Manual test - verify clear error message appears

### 6. Update error display in UI
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Catch `CastV2Error.invalidAddress` specifically
- Set `errorMessage` with user-friendly text
- **Validation:** Manual test - verify error displays correctly

## Verification Checklist
- [ ] Empty address triggers `invalidAddress` error
- [ ] Error message is user-friendly
- [ ] Re-discovery is triggered automatically when address is empty
- [ ] After re-discovery, casting works if device is found
- [ ] No regression for working devices
