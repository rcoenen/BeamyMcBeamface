# Proposal: Background Chromecast Discovery on Boot

## Problem Statement

Currently, Chromecast device discovery only happens when the user explicitly opens the "Select Chromecast..." modal. This causes several UX issues:

1. **Optimistic loading without validation**: On boot, the UI shows "Chromecast (Bedroom TV)" based solely on TOML config, without verifying the device is actually online.

2. **Delayed error feedback**: User doesn't discover their configured device is offline until they try to use it (click Play or open modal).

3. **Modal blocking on discovery**: Every time the modal opens, it runs a fresh 2-5 second network scan, blocking the UI.

4. **Stale cached results**: No way to refresh device list without closing and reopening modal.

## Proposed Solution

Implement a **shared discovery state system** with background discovery on boot:

### 1. Shared Discovery State

Add a single source of truth for discovery status:
```swift
enum DiscoveryState {
    case idle
    case scanning(started: Date)
    case completed(devices: [ChromecastDevice], timestamp: Date)
}
```

### 2. Background Discovery on Boot

- Immediately after UI initialization, trigger discovery on `DispatchQueue.global()`
- Discovery runs silently in background (no spinner on boot)
- When complete, validate configured device against discovered devices
- If configured device missing: auto-invalidate UI (clear config, revert to mpv)

### 3. Modal Reuses Discovery Results

When user opens "Select Chromecast..." modal:
- If `state == .scanning`: Show spinner, wait for completion
- If `state == .completed`: Show cached results immediately
- Add "Rescan" button to manually refresh device list

### 4. Auto-Invalidation Flow

If background discovery finds configured device is offline:
```
1. selectedChromecastName = nil
2. Radio label → "Chromecast (none)"
3. selectedOutput = .mpv (force switch)
4. TOML cleared + saved
5. (Silent - no error modal, just UI update)
```

User sees radio button smoothly switch from Chromecast to mpv within 2-5 seconds of boot.

## Scope

**In scope:**
- Shared `DiscoveryState` in TermKitTranscoderUI
- Background discovery triggered in `run()` after UI init
- Auto-invalidation when configured device not found
- Modal spinner when discovery already running
- Modal shows cached results when available
- "Rescan" button in modal to refresh device list

**Out of scope:**
- Periodic background refreshes while app running
- Device availability monitoring (detecting devices coming online)
- Smart caching based on network change events
- Multiple simultaneous discovery requests (only one can run at a time)

## Success Criteria

1. App boots instantly, discovery runs in background without blocking UI
2. If configured device offline, UI auto-corrects within 2-5 seconds of boot
3. Opening modal shows cached results immediately if recent discovery completed
4. Opening modal during boot shows spinner, waits for ongoing discovery
5. "Rescan" button in modal triggers fresh discovery with spinner
6. Only one discovery scan runs at a time (shared state prevents duplicates)

## Risks & Mitigations

- **Risk:** UI "flash" as radio switches from Chromecast to mpv after boot
  - **Mitigation:** Acceptable - smooth transition, better than error on Play

- **Risk:** Network discovery on every boot (slow on bad WiFi)
  - **Mitigation:** Runs in background, doesn't block UI; discovery is necessary for validation

- **Risk:** User opens modal during boot while discovery running
  - **Mitigation:** Modal shows spinner and waits; reuses the already-running scan

- **Risk:** Cached results become stale
  - **Mitigation:** "Rescan" button allows manual refresh; timestamp shown to user

## Related Changes

- Builds on `fix-chromecast-state-sync` (requires validation logic)
- Complements `add-output-selector` (improves device selection UX)
