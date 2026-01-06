# Spec: Matroska Streaming

## ADDED Requirements

### Requirement: TranscodeServer SHALL output Matroska container format

The TranscodeServer SHALL configure FFmpeg to output Matroska container format (`-f matroska`) instead of MPEG-TS for streaming to players.

**Related**: chromecast-compatibility

#### Scenario: FFmpeg configured with Matroska muxer
**Given** TranscodeServer is starting FFmpeg for transcoding
**When** FFmpeg arguments are built
**Then** arguments include `"-f", "matroska"`
**And** arguments do NOT include `"-f", "mpegts"`
**And** arguments do NOT include `"-mpegts_flags"`

#### Scenario: Matroska stream pipes to HTTP server
**Given** FFmpeg is running with Matroska output
**When** transcoded data is written to pipe
**Then** data contains Matroska EBML headers
**And** data contains H.264 video track
**And** data contains AAC audio track
**And** pipe data is sent to HTTP client socket

### Requirement: TranscodeServer SHALL serve Matroska streams with correct MIME type

The HTTP server SHALL respond with `Content-Type: video/x-matroska` for stream requests.

**Related**: chromecast-compatibility

#### Scenario: HTTP response headers contain Matroska MIME type
**Given** HTTP client connects to TranscodeServer
**When** HTTP response headers are sent
**Then** headers include `"Content-Type: video/x-matroska"`
**And** headers do NOT include `"Content-Type: video/mp2t"`

#### Scenario: Chromecast receives Matroska MIME type
**Given** Chromecast connects to stream URL
**When** Chromecast sends HTTP GET request
**Then** response contains `Content-Type: video/x-matroska`
**And** Chromecast accepts the stream
**And** no `LOAD_FAILED` error occurs

### Requirement: ChromecastPlayer SHALL load media with Matroska content type

The ChromecastPlayer SHALL specify `video/x-matroska` as the content type when loading media on Chromecast.

**Related**: chromecast-compatibility

#### Scenario: Chromecast LOAD command uses Matroska MIME type
**Given** ChromecastPlayer is loading media on Chromecast
**When** `loadMedia()` is called
**Then** Cast V2 LOAD message includes `"contentType": "video/x-matroska"`
**And** Cast V2 LOAD message includes `"streamType": "LIVE"`
**And** Chromecast accepts the media
**And** playback starts successfully

#### Scenario: Chromecast playback without LOAD_FAILED
**Given** Chromecast receiver app is launched
**And** media is loaded with `video/x-matroska` content type
**When** Chromecast begins buffering
**Then** no `LOAD_FAILED` message is received
**And** `MEDIA_STATUS` shows `playerState: "PLAYING"`
**And** video displays on Chromecast device

### Requirement: Matroska streaming SHALL support seeking

The Matroska stream SHALL support seeking operations on both mpv and Chromecast with accuracy comparable to MPEG-TS.

**Related**: playback-control

#### Scenario: Seek to position on Chromecast with Matroska
**Given** video is playing on Chromecast at 30.0s
**When** user seeks to 60.0s
**Then** Chromecast sends SEEK command
**And** TranscodeServer restarts FFmpeg at 60.0s
**And** FFmpeg outputs Matroska starting at seek position
**And** Chromecast resumes playback at 60.0s ±2s

#### Scenario: Seek to position on mpv with Matroska
**Given** video is playing on mpv at 45.0s
**When** user seeks to 90.0s
**Then** mpv reconnects to stream URL
**And** TranscodeServer restarts FFmpeg at 90.0s
**And** mpv resumes playback at 90.0s ±1s

#### Scenario: Random access via Matroska cue points
**Given** FFmpeg is encoding with keyframes every 30 frames (~1s)
**When** Matroska muxer writes output
**Then** cue points are created at each keyframe
**And** seeking lands on nearest cue point
**And** seek accuracy is within keyframe interval (±1s)

### Requirement: Matroska streaming SHALL maintain backward compatibility with mpv

The mpv player SHALL continue to play Matroska streams with identical functionality to MPEG-TS.

**Related**: playback-control

#### Scenario: mpv plays Matroska stream
**Given** TranscodeServer is streaming Matroska format
**When** mpv connects to stream URL
**Then** mpv recognizes Matroska container
**And** playback starts successfully
**And** video displays correctly
**And** audio plays correctly

#### Scenario: mpv playback controls work with Matroska
**Given** mpv is playing Matroska stream
**When** user presses play/pause
**Then** playback pauses and resumes correctly
**When** user seeks forward/backward
**Then** seek operations complete successfully
**When** position is queried
**Then** accurate position is returned (±1s)

## MODIFIED Requirements

None - this change adds Matroska support without modifying existing requirements.

## REMOVED Requirements

None - MPEG-TS is replaced, not deprecated (no spec existed for MPEG-TS).
