## Context
The TUI relies on `TranscodeServer.currentPosition` as the single authoritative time. Today this is derived from FFmpeg `-progress` `out_time`, which represents encode/output progress, not the stream timestamps that receivers actually play. This mismatch produces drift between the TUI and ffplay's displayed time.

## Goals / Non-Goals
- Goals:
  - Use MPEG-TS PTS from the outgoing stream to drive `currentPosition`.
  - Keep the transcoder as the single source of truth for UI state.
  - Improve alignment between TUI time and ffplay display time.
- Non-Goals:
  - Exact on-screen playback time for all receivers.
  - Player-side IPC or receiver feedback.
  - Protocol or container changes (remain MPEG-TS over HTTP).

## Decisions
- Decision: Parse PTS from outgoing MPEG-TS packets in the relay loop.
  - Rationale: PTS represents stream presentation timestamps and is the closest available clock to what receivers play, without needing receiver feedback.
- Decision: Maintain a monotonic `currentPosition` using latest PTS, ignoring backward jumps except after seek.
  - Rationale: Avoid UI jitter when packets arrive out of order or from discontinuities.

## Alternatives considered
- Keep FFmpeg `-progress` as-is: rejected because it reports encode time, not stream time.
- Add a constant offset: rejected due to variable buffer depth.
- Receiver feedback (mpv/Chromecast status): out of scope for this change.

## Risks / Trade-offs
- Risk: MPEG-TS PTS parsing complexity and edge cases (PAT/PMT, missing PTS, discontinuities).
  - Mitigation: Parse only PES headers for video packets and fall back to last known time.
- Risk: PTS jitter or wrap-around.
  - Mitigation: Apply monotonic guardrails and reset on seek.

## Migration Plan
1) Implement PTS parsing behind a feature flag or configuration toggle.
2) Validate TUI alignment in `transcode-test --tui` using timecode input.
3) Flip default to PTS-based time once validated.

## Open Questions
- Should PTS parsing be limited to video PID only, or accept any PTS-bearing stream?
- Do we need configuration to switch between `-progress` time and PTS time for troubleshooting?
