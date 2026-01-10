# Design: Roku Support

## Context

Roku devices expose an External Control Protocol (ECP) over HTTP on port 8060. This is a simple REST API that allows:
- Device discovery via SSDP
- Launching apps with parameters (including video URLs)
- Sending remote control keypresses

The `PlayOnRoku` feature (app ID 15985) accepts video URLs and plays them using Roku's built-in media player.

## Goals / Non-Goals

**Goals:**
- Discover Roku devices on local network
- Cast HLS streams from TranscodeServer to Roku
- Basic playback controls (play/pause, stop)

**Non-Goals:**
- Developing a custom Roku channel
- Seek to specific position (not well supported by ECP)
- Volume control

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      DeviceSelectorView                         │
│  (Shows Chromecast, AirPlay, Roku devices)                      │
└─────────────────────┬───────────────────────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    ▼                 ▼                 ▼
┌─────────┐    ┌───────────┐    ┌───────────┐
│Chromecast│   │  AirPlay  │    │   Roku    │
│Discovery │   │ Discovery │    │ Discovery │
└────┬─────┘   └─────┬─────┘    └─────┬─────┘
     │               │                │
     ▼               ▼                ▼
┌─────────┐    ┌───────────┐    ┌───────────┐
│Chromecast│   │  AirPlay  │    │   Roku    │
│ Player   │   │  Player   │    │  Player   │
└─────────┘   └───────────┘    └───────────┘
```

## SSDP Discovery

Roku discovery uses the same SSDP protocol as UPnP/DLNA:

```swift
// Multicast M-SEARCH
let message = """
M-SEARCH * HTTP/1.1\r
HOST: 239.255.255.250:1900\r
MAN: "ssdp:discover"\r
ST: roku:ecp\r
MX: 1\r
\r
"""

// Send to multicast address
socket.send(message, to: "239.255.255.250", port: 1900)

// Response contains LOCATION header
// LOCATION: http://192.168.1.100:8060/
```

## Video Casting

The PlayOnRoku endpoint accepts video URLs:

```swift
func cast(url: URL, name: String) async throws {
    let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    let castURL = URL(string: "http://\(device.address):8060/input/15985?t=v&u=\(encoded)&videoName=\(name)&videoFormat=hls")!

    var request = URLRequest(url: castURL)
    request.httpMethod = "POST"

    let (_, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw RokuError.castFailed
    }
}
```

## Playback Controls

Simple keypress commands:

```swift
func sendKey(_ key: String) async throws {
    let url = URL(string: "http://\(device.address):8060/keypress/\(key)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: request)
}

// Usage
try await sendKey("Play")  // Toggle play/pause
try await sendKey("Back")  // Stop and exit player
try await sendKey("Fwd")   // Fast forward
try await sendKey("Rev")   // Rewind
```

## Comparison with Chromecast

| Aspect | Chromecast | Roku |
|--------|------------|------|
| Discovery | mDNS | SSDP |
| Protocol | CastV2 (protobuf/TLS) | REST (HTTP) |
| Complexity | ~1000 LOC | ~200 LOC |
| Auth | None | None |
| HLS support | Yes | Yes |

## Risks / Trade-offs

### Risk: Seek not supported
The ECP API doesn't reliably support seeking to a specific position.

**Mitigation:** Accept this limitation. Users can use Fwd/Rev for relative seeking.

### Risk: No playback position feedback
Unlike Chromecast, Roku doesn't report current playback position.

**Mitigation:** For now, don't show progress bar for Roku. Future: poll device-info endpoint.

## Critical: Local Network Permission

macOS 11+ and iOS 14+ require local network access entitlement for SSDP/multicast.

**Required entitlement:**
```xml
<key>com.apple.developer.networking.multicast</key>
<true/>
```

**Info.plist:**
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Beamy needs local network access to discover Roku devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_roku._tcp</string>
</array>
```

Without this, SSDP discovery silently fails.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Discovery timeout (3s) | Show "No devices found" |
| Cast fails (non-200) | Show error toast, keep local playback |
| Device goes offline mid-playback | No detection (limitation), user retries |
| Network permission denied | Show "Enable Local Network in Settings" |

## Edge Cases (Follow Chromecast Pattern)

- **Same-name devices**: Append IP suffix, e.g. "Living Room (192.168.1.50)"
- **Stale devices**: Re-discover on each selector open, no caching
- **Multiple Rokus**: Show all, user picks

## Deferred

- SSDP retries/backoff (not needed for local network)
- Fwd/Rev buttons (hide in UI, ECP seek is unreliable)
- IPv6 (most home networks are IPv4)
- Playback position tracking (Roku doesn't report this well)

## Open Questions

1. Does PlayOnRoku work on all Roku models? (Testing needed)
2. Are there rate limits on ECP requests?
