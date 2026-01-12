# Change: Add Roku Casting Support

## Why

Roku devices are popular streaming players. By leveraging the Web Video Caster Receiver app (free in Roku Channel Store) and its reverse-engineered protocol, Beamy can cast HLS streams to Roku devices.

The old PlayOnRoku channel (15985) was disabled in Roku OS 11.5. We reverse-engineered the Web Video Caster protocol by capturing Android app traffic with PCAPdroid.

## What Changes

### User-Facing
- Roku appears as output option alongside Chromecast
- When selecting a Roku device, app checks if setup is complete
- If setup incomplete, shows popup window with step-by-step instructions
- Once setup verified, casting works seamlessly

### Technical
- SSDP discovery finds Roku devices on local network
- Detect ECP enabled via `/query/device-info` → `<ecp-setting-mode>`
- Detect Web Video Caster installed via `/query/apps` → channel ID 259656
- Cast using Web Video Caster protocol: `POST /input/259656?cmd=play&url=...`
- Playback controls via ECP keypress commands

## Roku Setup Requirements

Users must complete two steps (detected automatically by Beamy):

1. **Enable Roku Settings:**
   - Settings → System → Advanced system settings → Control by mobile apps → Enabled
   - Settings → System → Advanced system settings → Network access → Enabled

2. **Install Receiver App:**
   - Roku Channel Store → Search "Web Video Caster" → Install Receiver (free)

## Web Video Caster Protocol (Reverse Engineered)

```bash
# Launch receiver
POST http://<ip>:8060/launch/259656

# Play video
POST http://<ip>:8060/input/259656?cmd=play&url=<encoded_url>&tit=<title>&media=video&fmt=hls&pos=0&sub=false

# Control commands
POST /input/259656?cmd=state         # Get playback state
POST /input/259656?cmd=positionGet   # Get position
POST /keypress/Play                   # Play/pause
POST /keypress/Fwd                    # Fast forward
POST /keypress/Rev                    # Rewind
```

## Impact

- **New files:**
  - `RokuDevice.swift` - Device model
  - `RokuDiscovery.swift` - SSDP discovery
  - `RokuPlayer.swift` - Casting and controls (Web Video Caster protocol)
  - `RokuSelectorView.swift` - Device picker with setup status
  - `RokuSetupGuideView.swift` - Setup instructions popup window

- **Modified files:**
  - `CastingViewModel.swift` - Add Roku device handling
  - `ContentView.swift` - Add Roku output option

## Out of Scope

- Custom Roku channel development
- Audio-only streaming
- Subtitle support
