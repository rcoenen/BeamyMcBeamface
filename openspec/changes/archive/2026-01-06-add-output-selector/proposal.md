# Proposal: TermKit output selector with deferred launch

## Problem Statement
The current TermKit UI launches mpv immediately and assumes a single output. There is no way to pick Chromecast from inside the UI, switch outputs mid-session, or defer launching the player until the user chooses an output.

## Proposed Solution
- Add an “Output” selector in the TermKit UI (mpv or Chromecast).
- Defer launching any player until the first Play press.
- If Chromecast is selected:
  - Read preferred device from TOML; if missing/unavailable, show a discovery modal.
  - Allow selecting a device, save it back to TOML, then start casting.
- Allow switching outputs mid-session: stop the current player (mpv quit or Chromecast disconnect), then launch the newly selected output at the last known position and state.

## Scope
In scope:
- TermKit UI changes for output selection.
- Deferred player launch on first Play.
- Chromecast selection flow: config lookup, discovery modal, save to TOML.
- Output switching with cleanup and resume from last known position.

Out of scope:
- Non-TermKit paths.
- Advanced device priority rules; only preferred device + discovery fallback.
- Network/device health monitoring beyond initial availability check.

## Success Criteria
1) On start, no player is launched; Play triggers launch for the selected output.
2) Output selector allows mpv or Chromecast; switching outputs stops the old player and starts the new one.
3) Chromecast selection works via TOML preference or discovery modal, and saves selection to TOML.
4) Switching outputs resumes from last known position/state when possible.

## Risks & Mitigations
- **Risk:** Discovery finds no devices → Mitigation: show modal with “no devices found” and keep session paused.
- **Risk:** Switching outputs loses position → Mitigation: reuse last known position/pause state when starting the new output.
- **Risk:** TOML read/write errors → Mitigation: surface error in UI and let user retry discovery.
