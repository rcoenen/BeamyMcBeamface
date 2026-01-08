# Proposal: simplify-chromecast-connectivity

## Problem Statement

The app's URLSession-based reachability check fails with "The Internet connection appears to be offline" even when the Chromecast is online and Chrome can cast to it successfully. This caused an infinite retry loop that was hotfixed, but the underlying issue remains: URLSession cannot reach local network devices due to macOS privacy restrictions.

### Observed Behavior

```
[REACHABILITY] Checking if Bedroom TV @ 192.168.8.159 is reachable...
[REACHABILITY] Failed to reach http://192.168.8.159:8008/setup/eureka_info: The Internet connection appears to be offline.
[REACHABILITY] ❌ Device is NOT reachable
```

Yet Chrome casting to the same device on the same network works fine.

## Research Findings

### How Other Implementations Handle Chromecast Connections

| Implementation | Source | Approach |
|---------------|--------|----------|
| **VLC** | [videolan/vlc/chromecast.h](https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/chromecast.h) | Custom `vlc_tls` library, direct TLS socket |
| **PyChromecast** | [pychromecast/socket_client.py](https://github.com/home-assistant-libs/pychromecast/blob/master/pychromecast/socket_client.py) | Raw Python socket + `ssl.SSLContext`, `verify_mode = ssl.CERT_NONE` |
| **node-castv2** | [thibauts/node-castv2](https://github.com/thibauts/node-castv2) | Node.js `tls.connect()` with `rejectUnauthorized: false` |

**Key Finding**: All major implementations use **direct TLS socket connections** to port 8009. None use HTTP-based reachability checks.

### Cast V2 Protocol Connection Flow

From [node-castv2 documentation](https://github.com/thibauts/node-castv2) and [oakbits.com](https://oakbits.com/google-cast-protocol-discovery-and-connection.html):

1. **Discovery**: mDNS query for `_googlecast._tcp.local` (UDP multicast port 5353)
2. **Connection**: Direct TLS to device IP on port 8009
3. **Certificate**: Chromecast uses self-signed certs - must disable verification
4. **Protocol**: Protobuf messages over length-prefixed binary packets
5. **Virtual Connection**: Establish via `urn:x-cast:com.google.cast.tp.connection` namespace

The HTTP endpoint at port 8008 (`/setup/eureka_info`) is for device info queries, NOT for connection establishment.

### Why URLSession Fails on macOS

From [Apple Developer Forums](https://developer.apple.com/forums/thread/685814) and [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy):

- URLSession requires explicit Local Network permission via `NSLocalNetworkUsageDescription`
- Permission prompt only appears when URLSession actually tries to connect
- If permission is denied or not yet granted: "The Internet connection appears to be offline"
- NWConnection has different (less restrictive) permission behavior for direct socket connections

**Critical Insight**: Our `CastV2Client` uses `NWConnection` for TLS (correct approach), but our reachability check uses `URLSession` (wrong approach with different permission model).

### Why HTTP Reachability Check Is Unnecessary

1. **VLC doesn't do it**: Connects directly via TLS, handles failure gracefully
2. **PyChromecast doesn't do it**: Uses socket timeout (default 30 seconds)
3. **node-castv2 doesn't do it**: Relies on TLS connection timeout
4. **Our NWConnection already has timeout**: 10-second connection timeout built-in
5. **Address validation is sufficient**: `hasValidAddress` check catches empty/stale addresses

## Proposed Solution

Remove the URLSession-based `isDeviceReachable()` check entirely. Rely on:

1. **Address validation**: `hasValidAddress` property (already implemented)
2. **NWConnection timeout**: Built-in 10-second timeout in `connect()`
3. **Graceful error handling**: Clear error messages when connection fails

This aligns our implementation with VLC, PyChromecast, and node-castv2.

## Changes Required

1. Remove `isDeviceReachable()` function from `CastingViewModel.swift`
2. Remove reachability check calls from `showPromoOnChromecast()`
3. Remove reachability check calls from `launchChromecast()`
4. Update error messages to handle connection timeout gracefully
5. Remove `isRetryingConnection` flag (no longer needed)

## Out of Scope

- Changing the TLS connection mechanism (NWConnection is correct)
- Adding alternative reachability methods (unnecessary complexity)
- Modifying mDNS discovery (working correctly)

## Impact

- **User-facing**: Faster connection attempts (no 4-second HTTP timeout), clearer error messages
- **Code**: Simpler, fewer edge cases, aligned with industry implementations
- **Breaking changes**: None

## References

- [node-castv2 README](https://github.com/thibauts/node-castv2/blob/master/README.md) - Protocol documentation
- [PyChromecast socket_client.py](https://github.com/home-assistant-libs/pychromecast/blob/master/pychromecast/socket_client.py) - Python implementation
- [VLC chromecast.h](https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/chromecast.h) - C++ implementation
- [Apple Forums: URLSession local network](https://developer.apple.com/forums/thread/685814) - Permission issues
- [Google Cast Protocol](https://oakbits.com/google-cast-protocol-discovery-and-connection.html) - Protocol overview
