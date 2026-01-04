## 1. Implementation
- [ ] 1.1 Inspect current TranscodeServer streaming loop and identify where to tap outgoing MPEG-TS packets
- [ ] 1.2 Implement a minimal MPEG-TS parser that extracts PTS from PES headers for video packets
- [ ] 1.3 Update TranscodeServer to set `currentPosition` from latest observed PTS (seconds)
- [ ] 1.4 Keep FFmpeg `-progress` parsing for logging only, or remove if redundant
- [ ] 1.5 Add guardrails for monotonic time (ignore backwards jumps except on seek)

## 2. Validation
- [ ] 2.1 Manually run `transcode-test --tui` with timecode source and compare TUI time to ffplay display
- [ ] 2.2 Verify pause/resume does not advance `currentPosition` when no packets are emitted
- [ ] 2.3 Verify seek resets `currentPosition` to new PTS baseline after restart
