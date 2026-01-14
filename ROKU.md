# Roku Casting

## User Setup Instructions

To cast from Beamy to your Roku, complete these two steps:

### Step 1: Enable Roku Settings

On your Roku, go to:

1. **Settings → System → Advanced system settings → Control by mobile apps → Enabled**
2. **Settings → System → Advanced system settings → Network access → Enabled**

### Step 2: Install the Receiver App

1. Go to **Roku Channel Store**
2. Search for **"Web Video Caster"**
3. Install **"Web Video Caster - Receiver"** (free)

That's it! Beamy can now cast to your Roku.

---

## TODO: Test Next Session

- [ ] Drop video, verify progress bar shows real position from Roku polling
- [ ] Seek → should resume playing (no more 404 error)
- [ ] Pause via Roku remote → Beamy UI should update to show paused
- [ ] Resume via Roku remote → Beamy UI should update to show playing
- [ ] Verify polling logs in /tmp/beamy-debug.log

---

## Technical Notes

### Current Status: WORKING via Web Video Caster Receiver

Successfully reverse-engineered the Web Video Caster protocol by capturing Android app traffic with PCAPdroid.

### Channel ID: 259656

### Detecting Setup Requirements

Beamy can detect if the user has completed setup:

**1. Check if ECP is enabled:**
```bash
curl -s "http://<roku-ip>:8060/query/device-info" | grep "ecp-setting-mode"
# Returns: <ecp-setting-mode>enabled</ecp-setting-mode>
# If disabled or connection refused → prompt user to enable settings
```

**2. Check if Web Video Caster Receiver is installed:**
```bash
curl -s "http://<roku-ip>:8060/query/apps" | grep "259656"
# Returns: <app id="259656" ...>Web Video Caster - Receiver</app>
# If not found → prompt user to install from Channel Store
```

### Protocol (Reverse Engineered)

**Launch the receiver:**
```bash
POST http://<roku-ip>:8060/launch/259656
```

**Play a video:**
```bash
POST http://<roku-ip>:8060/input/259656?cmd=play&url=<encoded_url>&tit=<title>&media=video&fmt=<format>&pos=0&sub=false
```

**Parameters:**
- `cmd` - Command: `play`, `state`, `positionGet`, `mediaInfo`
- `url` - URL-encoded video URL (MP4, HLS, etc.)
- `tit` - Title to display
- `media` - Media type: `video` or `audio`
- `fmt` - Format: `mp4`, `hls`, etc.
- `pos` - Start position in seconds
- `sub` - Subtitles: `true` or `false`
- `callback` - Optional callback URL for status updates

**Example:**
```bash
# Launch receiver
curl -X POST "http://192.168.8.187:8060/launch/259656"

# Play Big Buck Bunny
curl -X POST "http://192.168.8.187:8060/input/259656?cmd=play&url=http%3A%2F%2Fcommondatastorage.googleapis.com%2Fgtv-videos-bucket%2Fsample%2FBigBuckBunny.mp4&tit=BigBuckBunny&media=video&fmt=mp4&pos=0&sub=false"
```

### Control Commands
```bash
# Get playback state
POST /input/259656?cmd=state

# Get current position
POST /input/259656?cmd=positionGet

# Get media info
POST /input/259656?cmd=mediaInfo
```

### Playback Control (via ECP keypress)
```bash
POST /keypress/Play
POST /keypress/Pause
POST /keypress/Rev      # Rewind
POST /keypress/Fwd      # Fast forward
```

## Known Limitations

### Seeking Shows Brief Splash Screen
When seeking, Beamy must restart the HLS stream at the new position. This causes the Web Video Caster Receiver to briefly show its splash screen before resuming playback. This is unavoidable with the current protocol.

## Failed Approaches

### PlayOnRoku (Channel ID: 15985)
- **Status:** Broken since Roku OS 11.5 (security restrictions)
- **Symptoms:** Flashes purple screen, then crashes
- Apps like Web Video Caster had to switch to custom receiver channels

### Roku Media Player (Channel ID: 2213)
- Only works with DLNA servers or USB drives
- No deep linking for external URLs

### Direct ECP to Web Video Caster
- Tried various parameter names (`u`, `url`, `mediaUrl`, `source`, `contentId`)
- All returned 200 OK but didn't trigger playback
- The `cmd=play` parameter was the missing piece!

## ECP (External Control Protocol) Reference

Base URL: `http://<roku-ip>:8060`

### Useful Endpoints
```
GET  /query/apps              # List installed channels
GET  /query/active-app        # Currently running app
GET  /query/device-info       # Device information
POST /launch/<channel-id>     # Launch a channel
POST /input/<channel-id>?params  # Send input to channel
POST /keypress/<key>          # Send remote key
```

### Key Codes
- `Play`, `Pause`, `Rev`, `Fwd`, `Select`, `Left`, `Right`, `Up`, `Down`, `Back`, `Home`

## Device Info

- **Roku Streaming Stick** @ `192.168.8.187`
- Model: 3840R
- Firmware: 15.0.4
- Web Video Caster Receiver: v1.8.0

## Code Location

- `Sources/BeamyKit/Roku/RokuPlayer.swift` - Roku ECP implementation
- `Sources/BeamyKit/Roku/RokuDiscovery.swift` - SSDP discovery

## References

- [Roku ECP Documentation](https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md)
- [Web Video Caster](https://www.webvideocaster.com/)
- [Roku OS 11.5 broke PlayOnRoku](https://community.roku.com/t5/Solving-playback-issues/OS-11-5-Roku-11-5-broke-Play-on-Roku-video-playback/td-p/827302)
