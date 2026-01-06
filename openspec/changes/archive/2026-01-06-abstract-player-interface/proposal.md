# Proposal: Abstract Player Interface

## Problem Statement

The TUI (TranscodeTest) currently has tight coupling to mpv via `if useMpv` conditionals throughout the codebase. This creates several issues:

1. **Code duplication**: Every playback control operation has separate paths for mpv vs fallback
2. **Inconsistent state tracking**: TUI tracks `intendedPauseState` locally because querying mpv during rapid seeks is unreliable
3. **No Chromecast support in TUI**: Cannot use interactive TUI controls with Chromecast (only automated test mode)
4. **Mixed responsibilities**: TUI code contains player-specific logic instead of delegating to player implementations

The current architecture queries player state (mpv IPC) but also has server state (TranscodeServer). This creates confusion about the source of truth for position and pause state.

## Proposed Solution

Create a `Player` protocol that abstracts playback control operations, with concrete implementations for:

- **MpvPlayer**: Wraps MpvController, uses IPC queries
- **ChromecastPlayer**: Parses MEDIA_STATUS messages for position/state
- **ServerPlayer** (fallback): Uses TranscodeServer state directly

This allows TUI to:
- Use single code path for all players (no `if useMpv` branches)
- Have consistent state queries regardless of player type
- Support Chromecast with same TUI controls as mpv
- Make player the canonical source of truth (what user sees), falling back to server

## Scope

**In Scope:**
- Define Player protocol with core playback operations
- Implement MpvPlayer (wraps existing MpvController)
- Refactor TUI to use Player protocol
- Add Chromecast MEDIA_STATUS parsing (position, playerState)
- Implement ChromecastPlayer

**Out of Scope:**
- Server-side state synchronization (seeking server from Chromecast)
- Multi-player support (one player instance at a time)
- Player lifecycle management (launch, teardown handled by TUI as before)

## Success Criteria

1. TUI code has zero `if useMpv` conditionals
2. TUI can control both mpv and Chromecast with same code path
3. Chromecast reports actual playback position from MEDIA_STATUS
4. Player is source of truth for position/pause state (server is fallback)
5. All existing TUI functionality works identically for mpv

## Dependencies

- Requires existing MpvController (no changes needed)
- Requires existing CastV2Client to expose MEDIA_STATUS parsing
- Event-driven FFmpeg coordination from feature/event-driven-server

## Risks & Mitigations

**Risk**: Breaking existing mpv functionality during refactor
**Mitigation**: Keep MpvController unchanged, only wrap it in MpvPlayer adapter

**Risk**: Chromecast MEDIA_STATUS may not provide all needed state
**Mitigation**: Fallback to server state when player state unavailable

**Risk**: Performance overhead from protocol abstraction
**Mitigation**: Player protocol uses simple method calls (no significant overhead)
