# Spec Delta: chromecast-connectivity

## REMOVED Requirements

### Requirement: HTTP reachability check before connection

The system previously performed an HTTP request to `http://<device>:8008/setup/eureka_info` before attempting TLS connection. This requirement is REMOVED.

#### Scenario: Reachability check removed
- **Given** a ChromecastDevice with valid address
- **When** `showPromoOnChromecast()` or `launchChromecast()` is called
- **Then** the system MUST NOT perform HTTP reachability checks
- **And** the system MUST proceed directly to TLS connection

**Rationale:** HTTP reachability checks via URLSession fail on macOS due to Local Network Privacy restrictions, causing "Internet connection appears to be offline" errors even when devices are reachable. Industry implementations (VLC, PyChromecast, node-castv2) do not use HTTP reachability checks.

## MODIFIED Requirements

### Requirement: Connection failure handling

The system MUST handle connection failures gracefully without infinite retry loops.

#### Scenario: Device unreachable (timeout)
- **Given** a ChromecastDevice with valid address but device is offline
- **When** TLS connection is attempted
- **Then** connection MUST timeout after 10 seconds
- **And** error message MUST be: "Could not connect to Chromecast. Check if it's powered on."
- **And** no automatic retry MUST occur

#### Scenario: Device with empty address
- **Given** a ChromecastDevice with empty address
- **When** connection is attempted
- **Then** connection MUST fail immediately with `invalidAddress` error
- **And** error message MUST be: "Device address not resolved. Please re-select the device."

#### Scenario: Device online and reachable
- **Given** a ChromecastDevice with valid address and device is online
- **When** connection is attempted
- **Then** TLS connection MUST succeed
- **And** promo image or media MUST load

### Requirement: Connection flow simplification

The system MUST use a simplified connection flow aligned with industry implementations.

#### Scenario: Simplified promo display flow
- **Given** output type is Chromecast and device is selected
- **When** `showPromoOnChromecast()` is called
- **Then** system MUST check `hasValidAddress` property
- **And** if address is empty, MUST show error and return
- **And** if address is valid, MUST attempt TLS connection directly
- **And** MUST NOT perform intermediate HTTP checks

#### Scenario: Simplified video cast flow
- **Given** output type is Chromecast and video file is loaded
- **When** `launchChromecast()` is called
- **Then** system MUST check `hasValidAddress` property
- **And** if address is empty, MUST throw `invalidAddress` error
- **And** if address is valid, MUST attempt TLS connection directly
- **And** MUST NOT perform intermediate HTTP checks

## Design References

This change aligns Beamy with industry-standard Chromecast implementations:

| Implementation | Connection Approach | HTTP Reachability Check |
|---------------|--------------------|-----------------------|
| **VLC** | Direct TLS via `vlc_tls` | None |
| **PyChromecast** | Direct TLS via Python `ssl` | None |
| **node-castv2** | Direct TLS via Node.js `tls` | None |
| **Beamy (after)** | Direct TLS via `NWConnection` | None |

Sources:
- [VLC chromecast.h](https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/chromecast.h)
- [PyChromecast socket_client.py](https://github.com/home-assistant-libs/pychromecast/blob/master/pychromecast/socket_client.py)
- [node-castv2](https://github.com/thibauts/node-castv2)
