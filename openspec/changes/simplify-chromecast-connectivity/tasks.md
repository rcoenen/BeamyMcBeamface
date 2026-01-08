# Tasks: simplify-chromecast-connectivity

## Implementation Order

### 1. Remove `isDeviceReachable()` function
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Delete the entire `isDeviceReachable(device:)` async function (lines ~857-888)
- This removes the URLSession-based HTTP check that causes "offline" errors
- **Validation:** Build succeeds, no references to `isDeviceReachable`

### 2. Simplify `showPromoOnChromecast()`
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Remove the reachability check block (the `do { let reachable = try await isDeviceReachable... }` section)
- Keep the `hasValidAddress` check (this is correct)
- Proceed directly to TLS connection after address validation
- Update error handling to show clear message on connection failure
- **Validation:** Build succeeds, promo attempts connect directly

### 3. Simplify `launchChromecast()`
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Remove the `isDeviceReachable()` call
- Keep the `hasValidAddress` guard
- Rely on NWConnection timeout for unreachable devices
- **Validation:** Build succeeds, video cast attempts connect directly

### 4. Remove `isRetryingConnection` flag
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Remove the `isRetryingConnection` property declaration
- Remove references in `selectedDevice.didSet`
- This flag was only needed for the retry loop which we're eliminating
- **Validation:** Build succeeds, no references to `isRetryingConnection`

### 5. Update error messages for connection failures
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Ensure `CastV2Error.connectionTimeout` shows: "Could not connect to Chromecast. Check if it's powered on."
- Ensure `CastV2Error.connectionFailed` shows: "Chromecast connection failed. Please try again."
- Keep `CastV2Error.invalidAddress` message as-is (already correct)
- **Validation:** Manual test - disconnect Chromecast, verify error message is clear

### 6. Clean up debug logging
**File:** `Sources/BeamyApp/CastingViewModel.swift`
- Remove `[REACHABILITY]` debug log calls (function is removed)
- Keep `[DISCOVERY]` and `[PROMO]` logging for diagnostics
- Update `[PROMO]` logs to reflect simplified flow
- **Validation:** Build succeeds, `/tmp/beamy-debug.log` shows clean flow

## Verification Checklist

- [x] Build succeeds with no warnings
- [x] No references to `isDeviceReachable` remain
- [x] No references to `isRetryingConnection` remain
- [x] App connects to online Chromecast successfully
- [x] App shows clear error for offline/unreachable Chromecast (after 10s timeout)
- [x] App shows clear error for device with empty address (immediate)
- [x] No infinite retry loops
- [x] Debug log shows simplified flow: DISCOVERY → PROMO → connect

## Rollback Plan

If issues arise, revert to commit before these changes. The previous implementation (with infinite loop fix) is functional, just slower due to unnecessary HTTP check.
