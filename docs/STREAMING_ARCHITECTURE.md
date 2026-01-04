# Streaming Architecture Deep Dive

This document captures our findings on how the Beamy transcoder streaming architecture works, the timing behaviors we observed, and the problems that remain to be solved.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              BEAMY STREAMING PIPELINE                           │
│                                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │   INPUT     │    │   FFMPEG    │    │  TRANSCODE  │    │    FFPLAY       │  │
│  │   FILE      │───▶│   ENCODER   │───▶│   SERVER    │───▶│   (RECEIVER)    │  │
│  │             │    │             │    │             │    │                 │  │
│  │  .mkv       │    │  libx264    │    │  HTTP/TCP   │    │  Displays       │  │
│  │  source     │    │  transcodes │    │  relay      │    │  video          │  │
│  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────────┘  │
│                                                                                 │
│  CONTROL PLANE:                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                        TranscodeServer (BeamyKit)                        │   │
│  │                                                                          │   │
│  │   • Owns playback state (isPaused, currentPosition)                     │   │
│  │   • Controls FFmpeg process (SIGSTOP/SIGCONT for pause/resume)          │   │
│  │   • Handles seek by killing and restarting FFmpeg with -ss              │   │
│  │   • Reports position via FFmpeg's -progress output                      │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  UI LAYER (stateless renderers):                                               │
│  ┌─────────────────┐    ┌─────────────────┐                                    │
│  │  TranscoderTUI  │    │ CastingViewModel │                                   │
│  │  (CLI)          │    │ (Mac App)        │                                   │
│  │                 │    │                  │                                   │
│  │  Queries server │    │  Queries server  │                                   │
│  │  for state      │    │  for state       │                                   │
│  └─────────────────┘    └─────────────────┘                                    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## The Buffer Pipeline

There are MULTIPLE buffers between FFmpeg encoding a frame and the user seeing it:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                            BUFFER PIPELINE                                       │
│                                                                                  │
│   FFmpeg encodes    FFmpeg's      Pipe        TCP         ffplay's    Display   │
│   frame             internal      buffer      socket      internal              │
│                     buffer                    buffer      buffer                │
│                                                                                  │
│   ┌─────────┐      ┌─────────┐   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌───────┐  │
│   │ ENCODE  │─────▶│ ENCODER │──▶│  PIPE   │─▶│  TCP   │─▶│ FFPLAY │─▶│ SHOW  │  │
│   │         │      │ BUFFER  │   │ BUFFER  │ │ BUFFER  │ │ BUFFER  │ │       │  │
│   └─────────┘      └─────────┘   └─────────┘ └─────────┘ └─────────┘ └───────┘  │
│       ↑                                                                          │
│       │                                                                          │
│   out_time                        ◀──────── ~7 seconds of buffering ──────────▶ │
│   reports                                                                        │
│   THIS position                                                                  │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Key Finding:** FFmpeg's `-progress` `out_time` reports the position of frames being ENCODED, not the position of frames being DISPLAYED. The ~7 second gap between TUI and video display is the sum of all these buffers.

---

## Encoding Speed vs Playback Speed

### Raw Encoding Speed (No Backpressure)

When encoding to a file with no downstream consumer throttling:

```
$ ffmpeg -i input.mkv -preset ultrafast -crf 23 -f mpegts output.ts

speed=20.7x
fps=495
```

FFmpeg can encode at **20x realtime** on an M2 Mac with ultrafast preset.

### Throttled Speed (With Backpressure)

When streaming through our pipeline:

```
speed=0.533x
speed=0.518x
speed=0.603x
speed=0.858x
```

FFmpeg is throttled to **~0.5x - 0.85x realtime**.

### Why The Slowdown?

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           BACKPRESSURE MECHANISM                                │
│                                                                                 │
│                                                                                 │
│   FFmpeg wants         Pipe buffer          ffplay consumes                     │
│   to write at          fills up             at 1x speed                         │
│   20x speed                                                                     │
│        │                   │                      │                             │
│        ▼                   ▼                      ▼                             │
│   ┌─────────┐         ┌─────────┐           ┌─────────┐                        │
│   │  20x    │────────▶│  FULL   │──────────▶│   1x    │                        │
│   │         │         │         │           │         │                        │
│   └─────────┘         └─────────┘           └─────────┘                        │
│        │                   │                                                    │
│        │                   │                                                    │
│        ▼                   ▼                                                    │
│   write() BLOCKS      FFmpeg slows down                                        │
│   waiting for         to match consumer                                         │
│   buffer space        (~1x with overhead)                                       │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

1. ffplay displays video at 1x realtime (can't go faster)
2. ffplay reads from TCP socket at ~1x
3. Our relay reads from pipe at ~1x
4. Pipe buffer fills up
5. FFmpeg's `write()` calls BLOCK waiting for space
6. FFmpeg is forced to slow down to ~1x

---

## Initial Buffer Buildup

When streaming starts:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         INITIAL BUFFER BUILDUP                                  │
│                                                                                 │
│   TIME        FFMPEG SPEED       PIPE STATE         BUFFER SIZE                │
│   ─────────────────────────────────────────────────────────────────            │
│                                                                                 │
│   T+0s        20x (full speed)   Empty               0 seconds                 │
│   T+0.1s      20x                Filling...          ~2 seconds                │
│   T+0.2s      20x                Filling...          ~4 seconds                │
│   T+0.3s      15x                Nearly full         ~6 seconds                │
│   T+0.4s      5x                 Full                ~7 seconds                │
│   T+0.5s+     ~1x (throttled)    Full (steady)       ~7 seconds (stable)       │
│                                                                                 │
│   ┌───────────────────────────────────────────────────────────┐                │
│   │                                                           │                │
│   │    ENCODING SPEED                                         │                │
│   │    ▲                                                      │                │
│   │ 20x│████                                                  │                │
│   │    │████                                                  │                │
│   │ 10x│████                                                  │                │
│   │    │████████                                              │                │
│   │  1x│████████████████████████████████████████████████████  │                │
│   │    └──────────────────────────────────────────────────▶   │                │
│   │         0.5s                                    TIME      │                │
│   │                                                           │                │
│   └───────────────────────────────────────────────────────────┘                │
│                                                                                 │
│   The ~7 second buffer is built up in the first ~0.5 seconds,                  │
│   then maintained at steady state.                                              │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Position Tracking Approaches

### Approach 1: Wall-Clock Time (FAILED)

**Assumption:** Playback advances at 1x wall-clock speed.

```swift
// WRONG - assumes encoding speed = playback speed
currentPosition = seekPosition + Date().timeIntervalSince(startTime) - pausedTime
```

**Why it failed:** FFmpeg encodes faster than realtime, so wall-clock time doesn't match encoding position OR display position.

### Approach 2: FFmpeg Progress (CURRENT)

**Assumption:** FFmpeg's `out_time` reflects what's being output.

```swift
// Parse from -progress pipe:2
// out_time=00:00:10.385375
currentPosition = parsedOutTime
```

**Problem:** `out_time` reports encoding position, which is ~7 seconds BEHIND display position due to buffering.

### Approach 3: Parse PTS from Stream (NOT IMPLEMENTED)

**Idea:** Parse presentation timestamps from MPEG-TS packets as we relay them.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          PTS PARSING APPROACH                                   │
│                                                                                 │
│   FFmpeg ──▶ MPEG-TS packets ──▶ Our relay ──▶ TCP ──▶ ffplay                  │
│                                      │                                          │
│                                      ▼                                          │
│                               Parse PTS from                                    │
│                               each packet                                       │
│                                      │                                          │
│                                      ▼                                          │
│                               currentPosition                                   │
│                               = latest PTS                                      │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Pro:** Would show exact position of frames being sent to receiver.
**Con:** Complex - requires parsing MPEG-TS packet headers.

---

## Pause/Resume Behavior

### Pause Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              PAUSE BEHAVIOR                                     │
│                                                                                 │
│   USER PRESSES SPACE                                                            │
│          │                                                                      │
│          ▼                                                                      │
│   TranscodeServer.pause()                                                       │
│          │                                                                      │
│          ▼                                                                      │
│   kill(pid, SIGSTOP)  ─────▶  FFmpeg STOPS immediately                         │
│                                                                                 │
│                               BUT...                                            │
│                                                                                 │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐                     │
│   │ FFMPEG  │    │ PIPE    │    │  TCP    │    │ FFPLAY  │                     │
│   │ STOPPED │    │ ~3s buf │───▶│ ~2s buf │───▶│ ~2s buf │───▶ DISPLAY        │
│   └─────────┘    └─────────┘    └─────────┘    └─────────┘                     │
│                                                                                 │
│   ffplay continues playing buffered data for ~7 seconds                        │
│   THEN video freezes                                                            │
│                                                                                 │
│   PERCEIVED PAUSE DELAY: ~7 seconds (variable based on buffer state)           │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Resume Flow (THE SPEED-UP PROBLEM)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         RESUME SPEED-UP PROBLEM                                 │
│                                                                                 │
│   BEFORE PAUSE:                                                                 │
│   • FFmpeg was at out_time = 10s                                               │
│   • ffplay displayed up to 17s (from buffer)                                   │
│   • Then buffer drained, video froze at ~17s                                   │
│                                                                                 │
│   USER PRESSES SPACE TO RESUME                                                  │
│          │                                                                      │
│          ▼                                                                      │
│   kill(pid, SIGCONT)  ─────▶  FFmpeg RESUMES from position 10s                 │
│                                                                                 │
│   FFmpeg outputs:  frame 10 ──▶ frame 11 ──▶ frame 12 ──▶ ...                  │
│                                                                                 │
│   ffplay receives frames with timestamps BEHIND where it froze                 │
│                                                                                 │
│   ffplay thinks: "These frames are OLD, I need to catch up!"                   │
│                                                                                 │
│   ffplay SPEEDS UP playback (2-3x) to reach "current time"                     │
│                                                                                 │
│   USER SEES: Video briefly plays at fast-forward speed                         │
│              Timecode races from 10s to 17s quickly                            │
│              Then resumes normal 1x playback                                   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Seek Behavior

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              SEEK FLOW                                          │
│                                                                                 │
│   USER ENTERS: s 120  (seek to 2:00)                                           │
│          │                                                                      │
│          ▼                                                                      │
│   TranscodeServer.seek(to: 120)                                                │
│          │                                                                      │
│          ├──▶ SIGCONT (in case paused)                                         │
│          ├──▶ process.terminate()                                              │
│          ├──▶ process.waitUntilExit()                                          │
│          │                                                                      │
│          ▼                                                                      │
│   startFFmpeg(at: 120)                                                         │
│          │                                                                      │
│          ▼                                                                      │
│   ffmpeg -ss 120 -copyts -i input.mkv ...                                      │
│                                                                                 │
│   • HTTP connection stays open (same socket)                                   │
│   • New FFmpeg streams from position 120                                       │
│   • MPEG-TS handles discontinuity gracefully                                   │
│   • ffplay shows new position after brief glitch                               │
│                                                                                 │
│   If was paused: re-pause after 100ms delay                                    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Observed Timing Discrepancies

### Test Setup

- **Input:** test_with_timecode.mkv (1 hour video with burnt-in SMPTE timecode)
- **Platform:** M2 Mac
- **FFmpeg preset:** ultrafast, CRF 23

### Observations

| Metric | Value |
|--------|-------|
| TUI shows | 00:00:10 |
| Video displays | 00:00:17 |
| **Gap** | **~7 seconds** |
| FFmpeg speed (throttled) | 0.5x - 0.85x |
| FFmpeg speed (to file) | 20.7x |

### Root Cause

The 7-second gap is the **total buffer size** across all stages:
- FFmpeg internal encoder buffer
- stdout pipe buffer (~64KB default on macOS)
- TCP socket buffer
- ffplay input buffer

---

## Problems To Solve

### Problem 1: Position Accuracy

**Current State:** TUI shows position ~7 seconds behind actual video display.

**Impact:** User sees incorrect timecode. Seeking to "2:00" in TUI means video jumps to approximately 2:00, but TUI shows 1:53.

**Possible Solutions:**

1. **Accept the offset** - Document that position is approximate
2. **Add constant offset** - Add ~7s to displayed position (fragile, varies)
3. **Parse PTS from stream** - Extract timestamps from MPEG-TS packets we relay
4. **Reduce buffering** - Use low-latency options to shrink the gap

### Problem 2: Pause Delay

**Current State:** ~7 seconds between pressing pause and video freezing.

**Impact:** User experience feels laggy and unresponsive.

**Possible Solutions:**

1. **Accept it** - This is inherent to buffered streaming
2. **Reduce buffering** - Smaller buffers = faster pause response, but may cause stuttering
3. **Pause ffplay too** - If we had IPC control over ffplay, we could pause both ends

### Problem 3: Speed-Up on Resume

**Current State:** Video plays at 2-3x speed briefly after unpausing.

**Impact:** Jarring user experience, timecode races visibly.

**Root Cause:** ffplay sees "old" timestamps and fast-forwards to catch up.

**Possible Solutions:**

1. **Accept it** - Inherent to how ffplay handles timestamp discontinuities
2. **Seek on resume** - Instead of SIGCONT, seek to current display position
3. **Use different player** - One with explicit pause/resume IPC (mpv with JSON IPC)

### Problem 4: Buffer Desync After Pause/Resume Cycles

**Current State:** After multiple pause/resume cycles, the position tracking may drift.

**Impact:** TUI position becomes increasingly inaccurate.

**Possible Solutions:**

1. **Periodic resync** - Parse PTS occasionally to correct drift
2. **Seek on resume** - Reset to known position each time

---

## FFmpeg Flags Reference

### Current Flags

```bash
-ss <time>           # Seek to position (before -i for fast seek)
-copyts              # Preserve original timestamps
-progress pipe:2     # Progress output to stderr
-stats_period 0.5    # Progress update interval
-flush_packets 1     # Flush after each packet
-fflags +flush_packets
-f mpegts            # MPEG-TS container (handles discontinuities)
```

### Low-Latency Options (Not Currently Used)

```bash
-tune zerolatency    # Minimize encoder latency (x264)
-fflags nobuffer     # Disable input buffering
-flags low_delay     # Low delay mode
-max_delay 0         # No muxer delay
-bf 0                # No B-frames (reduces latency)
```

**Trade-off:** Lower latency = more accurate position, but may cause stuttering if CPU can't keep up.

---

## Architecture Decisions

### Why TranscodeServer is Source of Truth

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                                                                 │
│   "The UI should own zero truth — only render whatever state it receives."     │
│                                                                                 │
│   BEFORE (distributed state):          AFTER (single source of truth):         │
│                                                                                 │
│   ┌─────────┐  isPlaying=true          ┌─────────────────────────────┐         │
│   │   TUI   │  currentPos=10           │      TranscodeServer        │         │
│   └─────────┘                          │                             │         │
│        ⚠️ Can desync!                  │  isPaused: Bool             │         │
│                                        │  currentPosition: Double     │         │
│   ┌─────────┐  isPlaying=false         │                             │         │
│   │ ViewModel│ currentPos=12           │  pause() / resume()         │         │
│   └─────────┘                          │  seek(to:)                  │         │
│        ⚠️ Can desync!                  │  togglePlayPause()          │         │
│                                        └──────────────┬──────────────┘         │
│   ┌─────────┐                                         │                        │
│   │ FFmpeg  │  actual position=???     ┌──────────────┴──────────────┐         │
│   └─────────┘                          │                             │         │
│                                   ┌────┴────┐               ┌────────┴───┐     │
│                                   │   TUI   │               │  ViewModel │     │
│                                   │ queries │               │   queries  │     │
│                                   │ server  │               │   server   │     │
│                                   └─────────┘               └────────────┘     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Why MPEG-TS Format

- Handles stream discontinuities (seek) without breaking connection
- No need for full file duration upfront
- Compatible with Chromecast and most players
- Self-contained packets (no external index)

### Why SIGSTOP/SIGCONT for Pause

- Simple, works with any FFmpeg build
- No special FFmpeg API needed
- Immediate effect on FFmpeg process
- Downside: buffer continues draining

---

## Future Improvements

1. **PTS Parsing** - Extract timestamps from MPEG-TS as we relay for accurate position
2. **Low-Latency Mode** - Optional mode with smaller buffers for tighter control
3. **Player IPC** - Use mpv with JSON IPC instead of ffplay for precise control
4. **Adaptive Buffering** - Dynamically adjust buffer based on network/CPU conditions

---

## Debug Tools

### View Progress Log

```bash
tail -f /tmp/beamy-transcoder-debug.log
```

### Test Raw Encoding Speed

```bash
ffmpeg -i input.mkv -t 60 -preset ultrafast -crf 23 -f mpegts -y /tmp/test.ts
# Look for speed=XXx at the end
```

### Check Buffer Sizes

```bash
# macOS pipe buffer size
sysctl kern.pipe.maxbuffer
# Default: 16384 (16KB), can be up to 1MB
```
