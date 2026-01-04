# Spec: TUI Player Integration

## MODIFIED Requirements

### Requirement: TUI SHALL use Player protocol instead of conditional logic

The TranscoderTUI SHALL use the Player protocol for all playback queries and controls, eliminating `if useMpv` conditional branches.

**Related**: player-protocol, mpv-player, chromecast-player, server-player

#### Scenario: Query position through Player protocol
**Given** TUI has a Player instance (MpvPlayer or ChromecastPlayer)
**When** TUI needs to display current position
**Then** it calls `player.getPosition()`
**And** displays the result without knowing the player type

#### Scenario: Query pause state through Player protocol
**Given** TUI has a Player instance
**When** TUI needs to display pause/play icon
**Then** it calls `player.isPaused()`
**And** displays ▶ (play) if true, ⏸ (pause) if false

#### Scenario: Control playback through Player protocol
**Given** TUI has a Player instance
**When** user presses space bar to toggle pause
**Then** TUI calls `player.isPaused()`
**Then** TUI calls `player.pause()` or `player.resume()` based on current state
**And** the operation works identically for mpv, Chromecast, or server fallback

## REMOVED Requirements

### Requirement: TUI SHALL NOT track pause state locally

The TUI SHALL no longer track `intendedPauseState` locally, as the Player protocol provides authoritative pause state.

#### Scenario: Remove intendedPauseState field
**Given** TUI refactored to use Player protocol
**When** pause state is needed
**Then** TUI queries `player.isPaused()`
**And** `intendedPauseState` field no longer exists

### Requirement: TUI SHALL NOT branch on player type

The TUI SHALL no longer use `if useMpv` or `useMpv: Bool` flag for conditional logic.

#### Scenario: Remove useMpv conditionals
**Given** TUI refactored to use Player protocol
**When** examining TUI code
**Then** zero `if useMpv` branches exist
**And** `useMpv` field no longer exists

#### Scenario: Remove mpvController field
**Given** TUI refactored to use Player protocol
**When** TUI needs mpv functionality
**Then** it uses `player: Player` instance (which may be MpvPlayer internally)
**And** `mpvController: MpvController?` field no longer exists

## ADDED Requirements

### Requirement: TUI SHALL use Player factory pattern

TUI SHALL use a factory function or initialization parameter to create the appropriate Player instance based on user choice.

**Related**: player-protocol, mpv-player, chromecast-player

#### Scenario: Create MpvPlayer for mpv mode
**Given** user runs `beamy transcode-test --mpv`
**When** TUI initializes
**Then** it creates `player = MpvPlayer(controller: mpvController)`
**And** all playback operations use this player

#### Scenario: Require player-capable mode
**Given** user runs `beamy transcode-test --tui`
**When** TUI initializes
**Then** it requires either `--mpv` or `--chromecast`
**And** exits with an error if neither is provided

### Requirement: TUI SHALL handle Player errors using last-known state

TUI SHALL catch errors from Player protocol methods and display last-known device state or error indicator when player is unavailable, WITHOUT falling back to server state.

**Related**: player-protocol

#### Scenario: Use last-known position on player error
**Given** TUI is using MpvPlayer
**And** last successful `player.getPosition()` returned 123.45
**When** `player.getPosition()` throws an error (e.g., mpv disconnected)
**Then** TUI catches the error
**And** displays last known position (123.45) or `00:00:00`
**And** does NOT use `server.currentPosition` for UI display
**And** continues operating (does not crash)

#### Scenario: Use last-known pause state on player error
**Given** TUI is using MpvPlayer
**And** last successful `player.isPaused()` returned `true`
**When** `player.isPaused()` throws an error
**Then** TUI displays ▶ (play) icon based on last known state
**And** does NOT use `server.isPaused` for UI display

#### Scenario: Display error state in TUI
**Given** TUI has no last-known state and player throws error
**When** rendering the UI
**Then** it displays `--:--:--` or a similar error indicator
**And** allows user to quit gracefully

### Requirement: TUI SHALL support Chromecast mode

TUI SHALL support using ChromecastPlayer for interactive control of Chromecast devices, enabling arrow key seeks, pause/play, etc.

**Related**: player-protocol, chromecast-player

#### Scenario: Use ChromecastPlayer in TUI
**Given** user runs `beamy transcode-test --chromecast <device-id>`
**When** TUI initializes
**Then** it creates `player = ChromecastPlayer(client: castClient)`
**And** arrow keys send seek commands to Chromecast
**And** space bar toggles pause on Chromecast
**And** TUI displays Chromecast's actual playback position
