# Change: Use stream PTS for transcoder time

## Why
The TUI uses the transcoder's `currentPosition` as the single source of truth, but the transcoder currently derives that time from FFmpeg `-progress` output. That time reflects encode/output progress, not the stream timestamps actually sent to receivers, which causes drift vs the displayed content.

## What Changes
- Derive `currentPosition` from MPEG-TS PTS values observed on the outgoing stream.
- Keep the transcoder as the authoritative source of truth for playback time, but base the clock on stream PTS rather than FFmpeg progress.
- Preserve existing UI behavior; TUI remains a stateless renderer of transcoder state.

## Impact
- Affected specs: `transcoder-timing` (new)
- Affected code: `Sources/BeamyKit/FFmpeg/TranscodeServer.swift` (progress parsing, stream relay)
- Behavioral change: reported time aligns to stream PTS instead of FFmpeg `out_time`
