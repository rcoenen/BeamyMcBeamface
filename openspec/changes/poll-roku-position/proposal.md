# Poll Roku Position

## Summary

Replace elapsed time estimation with actual position polling from Roku's `/query/media-player` endpoint.

## Problem

Currently, Beamy estimates the Roku playback position by tracking elapsed time since playback started. This approach:
- Drifts if the Roku buffers or stalls
- Loses accuracy after pause/resume cycles
- Cannot recover if the user controls playback directly on the Roku remote

## Solution

Roku's ECP provides `/query/media-player` which returns real-time playback state including:
```xml
<position>85118 ms</position>
<duration>734025 ms</duration>
<player state="play" error="false">
```

Poll this endpoint every ~1 second while Roku is playing to get accurate position data.

## Scope

- Add position polling to `CastingViewModel`
- Parse XML response for `<position>` element
- Update `currentTime` computed property to use polled value
- Keep elapsed time estimation as fallback if polling fails
- Update pause/play state from polled `state` attribute

## Out of Scope

- Polling other Roku data (buffering, format, etc.)
- Changing seek behavior (still requires stream restart)
