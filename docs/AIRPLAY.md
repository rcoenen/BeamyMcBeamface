# AirPlay Support for Beamy

## Overview

Adding AirPlay v1 video streaming support to Beamy, allowing users to beam videos to Apple TV and AirPlay-enabled devices.

**Status:** Phase 1 complete (discovery + UI), pairing next

---

## Protocol Summary

AirPlay v1 video is simple HTTP:

| Action | Request | Notes |
|--------|---------|-------|
| Get device info | `GET /server-info` | Returns XML plist |
| Play URL | `POST /play` | Body: `Content-Location` + `Start-Position` |
| Pause | `POST /rate?value=0` | |
| Resume | `POST /rate?value=1` | |
| Seek | `POST /scrub?position=X` | X in seconds (float) |
| Get position | `GET /scrub` | Returns duration + position |
| Get full status | `GET /playback-info` | XML plist with buffer info |
| Stop | `POST /stop` | |

### Common Headers

```
User-Agent: MediaControl/1.0
X-Apple-Session-ID: <uuid>
Content-Type: text/parameters
```

### Play Request Body

```
Content-Location: http://192.168.1.100:8080/stream.m3u8
Start-Position: 0
```

### Playback Info Response (XML plist)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>duration</key><real>3600.0</real>
    <key>position</key><real>120.5</real>
    <key>rate</key><real>1</real>
    <key>readyToPlay</key><true/>
</dict>
</plist>
```

---

## Device Discovery

**Bonjour service:** `_airplay._tcp.`

TXT record fields:
- `deviceid` - MAC address
- `features` - capability flags (hex)
- `model` - e.g., "AppleTV3,1"
- `srcvers` - AirPlay version

---

## Compatibility

### Works (AirPlay v1)
- Apple TV 2nd/3rd gen
- Apple TV 4/4K (with pairing)
- AirPlay-enabled TVs (Samsung, LG, Sony, Vizio)
- Some AirPlay speakers (video-capable ones)

### Requires Pairing (tvOS 10.2+)
Modern Apple TVs require one-time PIN pairing before accepting streams.

---

## Reference Implementation: pyatv

**Repository:** https://github.com/postlund/pyatv

Key files to study:
- `pyatv/airplay/player.py` - playback control
- `pyatv/airplay/srp.py` - pairing authentication
- `pyatv/airplay/auth/` - device authentication
- `pyatv/core/scan.py` - Bonjour discovery

### Example (pyatv)

```python
import pyatv

# Discover devices
atvs = await pyatv.scan(loop)

# Connect
atv = await pyatv.connect(atvs[0], loop)

# Play URL
await atv.stream.play_url("http://192.168.1.100:8080/stream.m3u8")

# Control
await atv.remote_control.pause()
await atv.remote_control.play()
```

---

## Beamy Implementation Plan

### Files to Create

```
Sources/BeamyKit/AirPlay/
├── AirPlayDevice.swift       # Device model
├── AirPlayDiscovery.swift    # Bonjour discovery
├── AirPlayClient.swift       # HTTP protocol client
├── AirPlayPlayer.swift       # Player protocol conformance
└── AirPlayPairing.swift      # PIN pairing (phase 2)
```

### Phase 1: Basic Playback (no auth)

1. **AirPlayDevice** - model with name, address, port, features
2. **AirPlayDiscovery** - NetServiceBrowser for `_airplay._tcp.`
3. **AirPlayClient** - HTTP client for /play, /rate, /scrub, /stop, /playback-info
4. **AirPlayPlayer** - conform to `Player` protocol

### Phase 2: Authentication

5. **AirPlayPairing** - SRP-based PIN pairing for tvOS 10.2+
6. Credential storage in Keychain

### Phase 3: UI Integration

7. Extend `OutputType` enum with `.airplay`
8. Add AirPlay device picker to UI
9. Add pairing flow UI

---

## Transcoder Compatibility

**Good news:** Beamy's HLS output (H.264 + AAC) is natively supported by AirPlay.

No transcoder changes needed - same stream works for both Chromecast and AirPlay.

---

## Architecture Fit

Current:
```
TranscodeServer → HLS → ChromecastPlayer → CastV2Client → Chromecast
```

With AirPlay:
```
TranscodeServer → HLS → AirPlayPlayer → AirPlayClient → Apple TV
                    ↘→ ChromecastPlayer → CastV2Client → Chromecast
```

Both players consume the same HLS stream URL.

---

## Resources

- [Unofficial AirPlay Specification](https://openairplay.github.io/airplay-spec/video/)
- [pyatv Documentation](https://pyatv.dev/)
- [pyatv GitHub](https://github.com/postlund/pyatv)
- [pyatv Stream API](https://pyatv.dev/development/stream/)
- [openairplay/ap2-sender](https://github.com/openairplay/ap2-sender) (Objective-C)

---

## Notes

- AirPlay v2 (AirPlay 2) adds multi-room audio and tighter encryption - not needed for video
- FairPlay DRM not required for local streaming
- Port 7000 is default for AirPlay video

---

## Progress

### Phase 1: Discovery & UI (Complete)

- [x] Protocol research
- [x] Reference implementation identified (pyatv)
- [x] AirPlayDevice model with feature flags (`Sources/BeamyKit/AirPlay/AirPlayDevice.swift`)
- [x] AirPlayDiscovery via NetServiceBrowser (`Sources/BeamyKit/AirPlay/AirPlayDiscovery.swift`)
- [x] Integration with CastingViewModel (discovery + device selection)
- [x] UI: 3-way output picker (Beamy | Chromecast | AirPlay)
- [x] UI: Separate device selectors per output type
- [x] UI: Lock icon for devices requiring pairing
- [x] Tested with Samsung 7 Series (50) - discovered, video-capable, requires pairing

### Phase 2: Pairing (Next)

- [ ] Research AirPlay pairing protocol (SRP-based)
- [ ] AirPlayPairing implementation
- [ ] PIN entry UI
- [ ] Credential storage (Keychain)

### Phase 3: Playback

- [ ] AirPlayClient (HTTP protocol)
- [ ] AirPlayPlayer (Player protocol conformance)
- [ ] End-to-end testing

---

## Tested Devices

| Device | Model | Features | Status |
|--------|-------|----------|--------|
| Samsung 7 Series (50) | URU7100 | VideoFairPlay, requires pairing | Discovered, pairing needed |
