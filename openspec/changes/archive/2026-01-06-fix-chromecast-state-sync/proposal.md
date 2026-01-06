# Proposal: Fix Chromecast State Synchronization

## Problem Statement

The TermKit UI has three related state values for Chromecast configuration that must remain synchronized:
1. **TOML config**: `config.chromecast.defaultDevice` (persistent storage)
2. **RadioGroup label**: `Chromecast (Bedroom TV)` (visual display)
3. **Discovery modal checkmark**: `✓ Bedroom TV` (configuration UI)

Currently these are out of sync:
- TOML has "Bedroom TV" ✓
- RadioGroup shows "Chromecast (Bedroom TV)" ✓
- Discovery modal opens with "None" selected ✗ (BUG!)

The root cause is confusion between two separate state variables:
- **`selectedOutput`**: Which player is CURRENTLY playing (mpv or chromecast) - ephemeral runtime state
- **`selectedChromecastName`**: Which Chromecast device is CONFIGURED as preferred - persistent configuration

The modal's `buildLabels()` function incorrectly uses `selectedOutput` to determine checkmarks, when it should only use `selectedChromecastName`.

## Proposed Solution

### 1. Separate Runtime State from Configuration

**Runtime State (ephemeral):**
- `selectedOutput: OutputChoice?` - Which radio button has the ●
- Determines what's playing RIGHT NOW
- Can switch between mpv ↔ chromecast without losing configuration

**Configuration State (persistent):**
- `selectedChromecastName: String?` - Which Chromecast is configured
- Synchronized with `config.chromecast.defaultDevice`
- NEVER cleared when switching to mpv output
- ONLY changed via "Select Chromecast..." button

### 2. Fix Modal Checkmark Logic

Change `buildLabels()` in discovery modal:
```swift
// BEFORE (WRONG):
let isActive = (self.selectedOutput == .chromecast && device.name == self.selectedChromecastName)

// AFTER (CORRECT):
let isActive = (device.name == self.selectedChromecastName)
```

The checkmark shows which device is CONFIGURED, not which is PLAYING.

### 3. Validate TOML Device on Modal Open

When opening the discovery modal:
1. Run discovery to find available devices
2. Check if `selectedChromecastName` exists in discovered devices
3. If NOT found (device offline/renamed):
   - Log warning
   - Clear `selectedChromecastName = nil`
   - Update radio label to "Chromecast (none)"
   - Clear TOML `config.chromecast.defaultDevice`
   - Modal shows checkmark on "None"

### 4. Synchronize All Three on Change

When user selects a device in modal and clicks OK:
1. Update `selectedChromecastName = device.name`
2. Rebuild RadioGroup label: "Chromecast (device.name)"
3. Save to TOML: `config.chromecast.defaultDevice = device.name`
4. Persist to disk: `config.save()`

When user selects "None" in modal:
1. Update `selectedChromecastName = nil`
2. Rebuild RadioGroup label: "Chromecast (none)"
3. Clear TOML: `config.chromecast.defaultDevice = nil`
4. Force `selectedOutput = .mpv` (can't play to nothing)
5. Persist to disk

## Scope

**In scope:**
- Fix `buildLabels()` checkmark logic to use configuration state only
- Add validation of TOML device against discovered devices
- Ensure radio label, TOML, and modal stay synchronized
- Prevent clearing `selectedChromecastName` when switching to mpv output

**Out of scope:**
- Handling offline devices during playback (user clicks Chromecast radio but device unreachable)
- Auto-reconnect logic
- Multiple Chromecast device support

## Success Criteria

1. On boot with `defaultDevice = "Bedroom TV"` in TOML, modal opens with ✓ on "Bedroom TV"
2. Selecting mpv radio button does NOT clear the configured Chromecast device
3. Radio label, TOML file, and modal checkmark always show the same device
4. If TOML device is not found during discovery, all three sources are cleared to "none"
5. Changing device in modal updates all three: label, TOML, and checkmark position

## Risks & Mitigations

- **Risk:** TOML device validation requires network discovery (slow on boot)
  - **Mitigation:** Only validate when opening modal, not on boot (optimistic load)

- **Risk:** User selects Chromecast radio but device is offline
  - **Mitigation:** Out of scope for this change; handle in separate error recovery proposal

- **Risk:** Breaking existing TOML configs
  - **Mitigation:** Gracefully handle missing/invalid `defaultDevice` field
