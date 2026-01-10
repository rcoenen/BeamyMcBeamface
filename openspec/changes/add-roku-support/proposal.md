# Change: Add Roku as Output Option

## Why

Roku devices are widely used streaming players that support a simple REST-based External Control Protocol (ECP). Unlike AirPlay which requires complex authentication, Roku accepts video URLs via HTTP POST and plays them directly - similar to Chromecast.

Adding Roku support expands Beamy's reach to another major streaming platform with minimal implementation effort.

## What Changes

- Add `RokuDevice.swift` - Device model (like ChromecastDevice)
- Add `RokuDiscovery.swift` - SSDP-based discovery
- Add `RokuPlayer.swift` - REST API for video playback
- Update UI to show Roku devices alongside Chromecast/AirPlay

**Technical approach:**

1. **Discovery** - SSDP multicast to `239.255.255.250:1900` with `ST: roku:ecp`
2. **Casting** - POST to `http://{ip}:8060/input/15985?t=v&u={URL}&videoFormat=hls`
3. **Controls** - POST to `http://{ip}:8060/keypress/{Play|Fwd|Rev|Back}`

## Roku ECP API

```
# Discover devices
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
ST: roku:ecp
MX: 1

# Cast HLS video
POST http://{ip}:8060/input/15985?t=v&u={url}&videoName={name}&videoFormat=hls

# Playback controls
POST http://{ip}:8060/keypress/Play   # toggle play/pause
POST http://{ip}:8060/keypress/Fwd    # fast forward
POST http://{ip}:8060/keypress/Rev    # rewind
POST http://{ip}:8060/keypress/Back   # stop/exit
```

## Impact

- Affected specs: New `roku-casting` capability
- Affected code:
  - `Sources/BeamyKit/Roku/RokuDevice.swift` - new
  - `Sources/BeamyKit/Roku/RokuDiscovery.swift` - new
  - `Sources/BeamyKit/Roku/RokuPlayer.swift` - new
  - `Sources/BeamyApp/DeviceSelectorView.swift` - add Roku section

## Out of Scope

- Roku channel/app development
- Audio-only streaming
- Remote control beyond basic playback
