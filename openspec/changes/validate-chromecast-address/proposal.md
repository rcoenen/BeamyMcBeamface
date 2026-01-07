# Proposal: validate-chromecast-address

## Problem Statement

The app fails with `CastV2Error error 2` (notConnected) when the saved Chromecast device has an empty or invalid IP address. This occurs because:

1. **Config only stores device name**: `ChromecastConfig.defaultDevice` saves only the device name (e.g., "Bedroom TV"), not the IP address
2. **mDNS resolution can fail**: When discovery runs, mDNS may not resolve the device address due to network hiccups, firewall issues, or timing
3. **No address validation**: `CastV2Client.connect()` attempts to connect to `device.address:8009` without checking if the address is valid
4. **Confusing error**: The log shows `Connecting to :8009 via TLS...` (empty host), and the user sees a generic "notConnected" error

Evidence from `/tmp/beamy-cast.log`:
```
Connecting to :8009 via TLS...
Connection state: waiting(-65554: NoSuchRecord)
```

## Proposed Solution

Add address validation before connecting and force re-discovery when the address is empty or stale.

### Changes

1. **Add address validation in `CastV2Client.connect()`**
   - Check `device.address.isEmpty` before creating connection
   - Throw new `CastV2Error.invalidAddress` with clear error message

2. **Add address validation in `CastingViewModel`**
   - Before using `selectedDevice`, verify `address` is non-empty
   - If address is empty, trigger re-discovery for that specific device
   - Show clear status message: "Re-discovering device..."

3. **Improve error messages**
   - `CastV2Error.invalidAddress` → "Device address not resolved. Please re-select the device."
   - Surface the specific error to the user instead of generic "notConnected"

## Out of Scope

- Address caching with TTL (can be added later if needed)
- Automatic reconnection on network changes
- IPv6 address validation

## Impact

- **User-facing**: Clear error message and automatic recovery instead of cryptic error
- **Code**: Minimal changes to `CastV2Client` and `CastingViewModel`
- **Breaking changes**: None
