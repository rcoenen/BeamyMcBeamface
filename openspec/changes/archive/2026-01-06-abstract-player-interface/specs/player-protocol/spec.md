# Spec: Player Protocol

## ADDED Requirements

### Requirement: System SHALL provide Player protocol for playback control

The system SHALL provide a Player protocol that defines a unified interface for controlling media playback across different player implementations (mpv, Chromecast, etc.).

#### Scenario: Query playback position
**Given** a Player implementation is active
**When** `getPosition()` is called
**Then** it returns the current playback position in seconds as TimeInterval
**And** throws an error if position is unavailable

#### Scenario: Query pause state
**Given** a Player implementation is active
**When** `isPaused()` is called
**Then** it returns `true` if playback is paused, `false` if playing
**And** throws an error if state is unavailable

#### Scenario: Pause playback
**Given** a Player implementation is playing media
**When** `pause()` is called
**Then** playback pauses
**And** subsequent `isPaused()` calls return `true`

#### Scenario: Resume playback
**Given** a Player implementation has paused media
**When** `resume()` is called
**Then** playback resumes
**And** subsequent `isPaused()` calls return `false`

#### Scenario: Seek to position
**Given** a Player implementation is playing media
**When** `seek(to: 120.0)` is called
**Then** playback jumps to 120 seconds
**And** `getPosition()` returns approximately 120.0

#### Scenario: Reload stream
**Given** a Player implementation is playing a stream
**When** `reload(url: newURL)` is called
**Then** the player reloads the stream from the new URL
**And** playback continues from the beginning of the new stream

### Requirement: Player protocol SHALL use error handling

The Player protocol SHALL use Swift error handling (throws) for all operations that can fail, allowing callers to handle unavailability gracefully.

#### Scenario: Handle unavailable player state
**Given** a Player implementation cannot determine its state
**When** any protocol method is called
**Then** it throws a descriptive error
**And** the caller can catch and handle the error (e.g., display last known state or error indicator)

### Requirement: Player protocol SHALL be implementation-agnostic

The Player protocol SHALL NOT expose implementation details specific to any particular player type (mpv, Chromecast, etc.).

#### Scenario: Abstract position source
**Given** the Player protocol defines `getPosition()`
**When** implemented by MpvPlayer
**Then** it uses mpv IPC internally
**When** implemented by ChromecastPlayer
**Then** it uses MEDIA_STATUS internally
**And** callers are unaware of the difference
