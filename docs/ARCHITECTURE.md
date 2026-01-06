# Beamy Architecture (Conceptual)

This document describes the high-level data flow for playback and control. It is intended as a quick mental model for how the app behaves.

## Big Picture

Beamy does not control a local file player directly. Instead, it controls a transcoder service that streams bytes to any playback client.

```
┌────────────────────────────────────────────────────────────────────────────┐
│                            BEAMY APP (Mac)                                 │
│                                                                            │
│  ┌─────────────────┐                                                       │
│  │    DROP ZONE    │◀──── User drops MKV file                              │
│  └────────┬────────┘                                                       │
│           │                                                                │
│           │ triggers                                                       │
│           ▼                                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                      TRANSCODER (FFmpeg)                             │  │
│  │                                                                      │  │
│  │   INPUT                                         OUTPUT               │  │
│  │  ┌─────────┐                                 ┌─────────────┐        │  │
│  │  │  MKV    │ ─────── transcode ────────────▶ │ HTTP stream │        │  │
│  │  │  file   │                                 │ (port 8080) │        │  │
│  │  └─────────┘                                 └──────┬──────┘        │  │
│  │       ▲                                             │               │  │
│  │       │                                             │               │  │
│  └───────┼─────────────────────────────────────────────┼───────────────┘  │
│          │                                             │                   │
│          │ controls INPUT                              │                   │
│          │ (seek, play, pause)                         │                   │
│          │                                             │                   │
│  ┌───────┴─────────┐                                   │                   │
│  │      UI         │                                   │                   │
│  │  ┌───────────┐  │                                   │                   │
│  │  │ ◀◀  ▶  ▶▶ │  │                                   │                   │
│  │  │ ▬▬▬●▬▬▬▬▬ │  │                                   │                   │
│  │  └───────────┘  │                                   │                   │
│  └─────────────────┘                                   │                   │
│                                                        │                   │
│  ┌─────────────────┐                                   │                   │
│  │   IN-APP        │◀──────────────────────────────────┤                   │
│  │   PREVIEW       │   dumb receiver #3                │                   │
│  │   ┌─────────┐   │                                   │                   │
│  │   │  ▶ ───  │   │                                   │                   │
│  │   └─────────┘   │                                   │                   │
│  └─────────────────┘                                   │                   │
│                                                        │                   │
└────────────────────────────────────────────────────────┼───────────────────┘
                                                         │
                    ┌────────────────────────────────────┼────────────────┐
                    │                                    │                │
                    ▼                                    ▼                ▼
           ┌────────────────┐                  ┌──────────────┐   ┌───────────┐
           │   CHROMECAST   │                  │     VLC      │   │  other    │
           │                │                  │              │   │  players  │
           │   dumb #1      │                  │   dumb #2    │   │           │
           │   (production) │                  │   (testing)  │   │           │
           └────────────────┘                  └──────────────┘   └───────────┘
```

**Key insight:**
- UI controls talk to **TRANSCODER INPUT** (left side)
- All receivers (including in-app preview) tap the **TRANSCODER OUTPUT** (right side)
- The receivers are "dumb" - they only display what comes in

## Control Plane vs Data Plane

- Control plane: UI/ViewModel -> TranscodeServer (play, pause, seek).
- Data plane: FFmpeg -> TranscodeServer -> HTTP stream -> Playback client.

## Key Roles

- UI / ViewModel: Owns user intent (play, pause, seek) and forwards it to the transcoder.
- TranscodeServer: Local HTTP server that feeds the stream to clients. It controls the FFmpeg process.
- FFmpeg process: Reads the source file, transcodes it, and writes to the HTTP stream.
- Playback Client: Chromecast, VLC, or the in-app preview. It only reads the live stream.

## Playback Behavior

The playback clients are effectively "dumb": they show whatever the live stream provides. UI controls operate the transcoder INPUT, not the output stream. Changes show up on clients after a short buffer delay.

**Important:** There are NO HTTP Range requests. This is a live stream, not a seekable file. All control happens on the INPUT side.

### Play/Pause

```
User clicks PAUSE
        │
        ▼
┌───────────────┐         ┌─────────────────────────────────────┐
│      UI       │────────▶│           TRANSCODER                │
│ [▶] → [⏸]    │  SIGSTOP │  INPUT: FFmpeg stops reading        │
└───────────────┘         │  OUTPUT: stream freezes (no bytes)  │
                          └──────────────────┬──────────────────┘
                                             │
                                             ▼
                          ┌─────────────────────────────────────┐
                          │          DUMB RECEIVERS             │
                          │  Buffer drains → frozen frame       │
                          │  (they don't "know" it's paused)    │
                          └─────────────────────────────────────┘

User clicks PLAY
        │
        ▼
┌───────────────┐         ┌─────────────────────────────────────┐
│      UI       │────────▶│           TRANSCODER                │
│ [⏸] → [▶]    │  SIGCONT │  INPUT: FFmpeg resumes reading      │
└───────────────┘         │  OUTPUT: stream flows again         │
                          └──────────────────┬──────────────────┘
                                             │
                                             ▼
                          ┌─────────────────────────────────────┐
                          │          DUMB RECEIVERS             │
                          │  New bytes arrive → video continues │
                          └─────────────────────────────────────┘
```

### Seek

```
User drags seek bar to 20:00
        │
        ▼
┌───────────────┐         ┌─────────────────────────────────────┐
│      UI       │────────▶│           TRANSCODER                │
│ ▬▬▬▬▬●▬▬▬▬▬▬ │  seek    │  INPUT: FFmpeg restarts at 20:00    │
│      ↑        │  20:00  │  OUTPUT: new frames from 20:00      │
│   20 min      │         └──────────────────┬──────────────────┘
└───────────────┘                            │
                                             ▼
                          ┌─────────────────────────────────────┐
                          │          DUMB RECEIVERS             │
                          │  Stream now shows 20:00 content     │
                          │  (they just display what arrives)   │
                          └─────────────────────────────────────┘
```

### Key Points

1. **No HTTP Range requests** - that's for seekable files. We have a live stream.
2. **Output doesn't "seek"** - it just keeps flowing. Content changes because INPUT changed.
3. **Receivers are oblivious** - they don't know about play/pause/seek. They just render bytes.
4. **Pause = silence on the wire** - FFmpeg stops producing, stream stops flowing, receivers freeze.
5. **Seek = new content** - FFmpeg jumps to new position, stream continues with different frames.

## Sequence Diagram

```
User        UI/ViewModel        TranscodeServer        FFmpeg        Dumb Receivers
 |               |                    |                  |                 |
 | click Play    |------------------->|  SIGCONT         |                 |
 |               |                    |----------------->|                 |
 |               |                    |                  | writes stream   |
 |               |                    |                  |────────────────>| video plays
 |               |                    |                  |                 |
 | click Pause   |------------------->|  SIGSTOP         |                 |
 |               |                    |----------------->|                 |
 |               |                    |                  | (stops)         |
 |               |                    |                  |      (silence)  | buffer drains
 |               |                    |                  |                 | frozen frame
 |               |                    |                  |                 |
 | drag Seek     |------------------->| kill + restart   |                 |
 |               |                    |----terminate---->|                 |
 |               |                    |---spawn @ 20m--->| new stream      |
 |               |                    |                  |────────────────>| shows 20:00
 |               |                    |                  |                 |
```

## Where to Look in Code

- Control flow: `Sources/BeamyApp/CastingViewModel.swift`
- Transcode control: `Sources/BeamyKit/FFmpeg/TranscodeServer.swift`
