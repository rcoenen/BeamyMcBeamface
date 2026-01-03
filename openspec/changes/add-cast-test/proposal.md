# Change: Add cast-test command

## Why
Need a way to quickly test Chromecast connectivity without transcoding a video file. This helps verify device discovery, network connectivity, and the casting pipeline works end-to-end.

## What Changes
- Add `StaticFileServer` class for serving static files via HTTP
- Add `cast-test` command that displays the Beamy McBeamface test image on Chromecast
- Support `--device` flag for device selection
- Filter to only video-capable devices (consistent with other commands)

## Impact
- Affected specs: None (new capability)
- Affected code: Server/ (new), Commands/ (new), Beamster.swift (registration)
