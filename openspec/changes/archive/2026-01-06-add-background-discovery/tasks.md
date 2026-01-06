# Tasks: Background Chromecast Discovery

## Phase 1: Add Shared Discovery State

### 1. Define DiscoveryState enum
- [ ] Create `DiscoveryState` enum in TermKitTranscoderUI.swift
- [ ] Add cases: `.idle`, `.scanning(started: Date)`, `.completed(devices: [ChromecastDevice], timestamp: Date)`
- [ ] Add `discoveryState` property with thread-safe access
- [ ] Consider using `DispatchQueue` or `NSLock` for thread safety
- **Validation**: Enum compiles, property accessible

### 2. Add discovery state management methods
- [ ] Create `startBackgroundDiscovery()` method
- [ ] Create `handleDiscoveryComplete(devices: [ChromecastDevice])` method
- [ ] Create `autoInvalidateConfiguredDevice(devices: [ChromecastDevice])` method
- [ ] Ensure all state transitions use proper locking
- **Validation**: Methods compile, state machine works correctly

## Phase 2: Background Discovery on Boot

### 3. Trigger discovery in run()
- [ ] After UI initialization completes (after `Application.top.addSubview(top)`)
- [ ] Before `Application.run()` is called
- [ ] Call `startBackgroundDiscovery()` on `DispatchQueue.global(qos: .userInitiated)`
- [ ] Set initial state to `.scanning`
- [ ] Log: "Starting background Chromecast discovery"
- **Validation**: Discovery starts immediately after UI appears

### 4. Implement background discovery flow
- [ ] In `startBackgroundDiscovery()`, check if already `.scanning` or have recent `.completed`
- [ ] Run `ChromecastDiscovery.discover(timeout:)` on background queue
- [ ] On completion, call `handleDiscoveryComplete(devices:)` on main thread
- [ ] Update state to `.completed(devices, timestamp: Date())`
- [ ] Log discovered devices
- **Validation**: Discovery runs without blocking UI

### 5. Implement auto-invalidation logic
- [ ] In `handleDiscoveryComplete()`, call `autoInvalidateConfiguredDevice()`
- [ ] Check if `selectedChromecastName` exists in discovered devices
- [ ] If NOT found:
  - [ ] Clear `selectedChromecastName = nil`
  - [ ] Set `selectedOutput = .mpv`
  - [ ] Clear `config.chromecast.defaultDevice`
  - [ ] Call `config.save()`
  - [ ] Call `rebuildOutputRadio(chromecastName: nil, selected: .mpv)`
  - [ ] Log: "Background discovery: 'Device Name' not found - auto-invalidating"
- [ ] All UI updates must happen on main thread
- **Validation**: UI auto-corrects when device offline

## Phase 3: Modal Integration with Shared State

### 6. Refactor presentDiscovery() to check state
- [ ] At start of `presentDiscovery()`, check `discoveryState`
- [ ] If `.scanning`: Show spinner, wait for completion, then show dialog
- [ ] If `.completed`: Skip discovery, use cached devices, show dialog immediately
- [ ] If `.idle`: Start new discovery (existing flow)
- [ ] **Validation**: Modal reuses cached results when available

### 7. Add waiting logic for in-flight discovery
- [ ] Create `waitForDiscoveryCompletion(completion:)` method
- [ ] Poll or subscribe to state changes
- [ ] When state becomes `.completed`, invoke completion handler with devices
- [ ] Timeout after reasonable period (e.g., 10 seconds)
- [ ] **Validation**: Modal waits for boot discovery to complete

### 8. Update showDiscoveryDialog() to handle cached results
- [ ] If called with cached results, skip spinner logic
- [ ] Ensure `buildLabels()` works with any device array
- [ ] Handle case where cached results are empty (no devices found)
- [ ] **Validation**: Modal displays correctly with cached or fresh results

## Phase 4: Add Rescan Capability

### 9. Add "Rescan" button to modal
- [ ] Add `Button("Rescan")` to modal dialog
- [ ] Position near OK/Cancel buttons
- [ ] Style appropriately (maybe info/secondary color)
- [ ] **Validation**: Button appears in modal

### 10. Implement rescan logic
- [ ] On button click, reset `discoveryState = .idle`
- [ ] Call `startBackgroundDiscovery()` to trigger fresh scan
- [ ] Show spinner in modal while scanning
- [ ] Update device list in modal when scan completes
- [ ] Update timestamp display
- [ ] **Validation**: Rescan triggers fresh network discovery

### 11. Add timestamp display to modal
- [ ] Extract timestamp from `.completed(devices, timestamp)`
- [ ] Calculate elapsed time (e.g., "Last scanned: 12s ago")
- [ ] Display in modal (maybe subtitle or footer)
- [ ] Update dynamically if modal stays open
- [ ] **Validation**: Timestamp shows correct elapsed time

### 12. Handle rescan edge cases
- [ ] If already `.scanning`, disable button or show "Scanning..."
- [ ] If rescan fails, show error but keep old cached results
- [ ] Log rescan events for debugging
- [ ] **Validation**: Rescan handles errors gracefully

## Phase 5: Thread Safety

### 13. Implement thread-safe state access
- [ ] Use `DispatchQueue(label: "com.beamy.discovery")` for state synchronization
- [ ] Or use `NSLock` around state reads/writes
- [ ] Ensure all state mutations happen via synchronized access
- [ ] **Validation**: No crashes from concurrent access

### 14. Ensure UI updates on main thread
- [ ] Audit all UI updates in discovery flow
- [ ] Wrap in `DispatchQueue.main.async { }` if needed
- [ ] RadioGroup updates
- [ ] Status label updates
- [ ] Modal list updates
- [ ] **Validation**: No "UIKit on background thread" errors

## Phase 6: Testing and Validation

### 15. Test boot with valid device
- [ ] Set TOML: `chromecast.defaultDevice = "Bedroom TV"`
- [ ] Ensure "Bedroom TV" is on network
- [ ] Boot app
- [ ] Verify: No UI change (stays "Chromecast (Bedroom TV)")
- [ ] Check logs: "Background discovery: ... devices found"
- [ ] **Validation**: Boot discovery validates device silently

### 16. Test boot with offline device
- [ ] Set TOML: `chromecast.defaultDevice = "Offline Device"`
- [ ] Ensure device is NOT on network
- [ ] Boot app
- [ ] Verify: UI shows "Chromecast (Offline Device)" briefly (~2s)
- [ ] Verify: UI auto-corrects to "mpv" radio selected, "Chromecast (none)"
- [ ] Check logs: "auto-invalidating"
- [ ] **Validation**: Auto-invalidation works correctly

### 17. Test modal during boot discovery
- [ ] Boot app
- [ ] Immediately click "Select Chromecast..." (within 2 seconds)
- [ ] Verify: Spinner appears in modal
- [ ] Verify: No duplicate network scan
- [ ] Verify: Devices appear when boot discovery completes
- [ ] **Validation**: Modal reuses in-flight discovery

### 18. Test modal after boot discovery
- [ ] Boot app, wait 10 seconds
- [ ] Click "Select Chromecast..."
- [ ] Verify: Modal opens instantly (no spinner)
- [ ] Verify: Devices shown immediately from cache
- [ ] Verify: Timestamp shown ("Last scanned: Xs ago")
- [ ] **Validation**: Cached results used correctly

### 19. Test rescan button
- [ ] Open modal with cached results
- [ ] Click "Rescan" button
- [ ] Verify: Spinner appears
- [ ] Verify: Fresh network scan runs
- [ ] Verify: Device list updates
- [ ] Verify: Timestamp updates
- [ ] **Validation**: Rescan triggers fresh discovery

### 20. Test concurrent discovery protection
- [ ] Trigger background discovery
- [ ] Before it completes, try to start another discovery
- [ ] Verify: Second request reuses first (no duplicate)
- [ ] Verify: No race conditions or crashes
- [ ] **Validation**: Only one discovery at a time

### 21. Add unit tests
- [ ] Test `DiscoveryState` transitions
- [ ] Test auto-invalidation logic
- [ ] Test thread-safe state access
- [ ] Mock `ChromecastDiscovery` for deterministic testing
- [ ] **Validation**: All tests pass

## Dependencies

- **Requires**: `fix-chromecast-state-sync` (uses validation logic)
- **Parallel**: Tasks 1-2 can be done in parallel
- **Sequential**: Phase 2 depends on Phase 1 (need state before using it)
- **Sequential**: Phase 3 depends on Phase 2 (need background discovery working)
- **Parallel**: Phase 4 (rescan) can overlap with Phase 5 (thread safety)
- **Blocking**: Phases 1-5 must complete before testing (Phase 6)

## Out of Scope (Future Work)

- Periodic background refreshes while app is running
- Network change detection and automatic rescan
- Smart cache invalidation (e.g., WiFi network changed)
- Device availability monitoring (detecting devices coming online)
- Multiple discovery requests queued (only one at a time supported)
