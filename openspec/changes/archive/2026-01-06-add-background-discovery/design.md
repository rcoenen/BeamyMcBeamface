# Design: Background Chromecast Discovery

## Architectural Pattern

This implements a **Shared State Background Task** pattern with lazy UI updates:

- **Single State Machine**: One `DiscoveryState` tracks the global discovery status
- **Background Execution**: Discovery runs on `DispatchQueue.global()` without blocking UI
- **Reactive UI**: Components subscribe to state changes and update accordingly
- **Idempotent Operations**: Multiple requests to discover reuse in-flight scans

Similar patterns:
- **Image Loading Libraries**: Background fetch, cached results, placeholder while loading
- **Network Status Monitors**: Background ping, UI subscribes to connectivity changes
- **App Store Auto-Updates**: Background check on launch, silent updates

## State Machine

```
┌─────────────────────────────────────────────────────────┐
│                   DiscoveryState                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  .idle                                                   │
│    ↓ (on boot)                                           │
│  .scanning(started: Date)                                │
│    ↓ (discovery completes)                               │
│  .completed(devices: [ChromecastDevice], timestamp)      │
│    ↓ (user clicks "Rescan")                              │
│  .scanning(started: Date)                                │
│    ↓                                                     │
│  .completed(...)                                         │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

**State Transitions:**
```swift
enum DiscoveryState {
    case idle
    case scanning(started: Date)
    case completed(devices: [ChromecastDevice], timestamp: Date)
}

// Only one scan at a time
func startDiscovery() {
    guard case .idle = discoveryState else {
        // Already scanning or have results - ignore
        return
    }
    discoveryState = .scanning(started: Date())
    // ... run discovery ...
}
```

## Flow Diagrams

### Boot Flow
```
App Launch
  ↓
UI Init (instant)
  ├─ Load TOML config
  ├─ Show "Chromecast (Bedroom TV)" optimistically
  └─ Trigger background discovery
      ↓ (DispatchQueue.global)
  Network scan (2-5 sec)
      ↓
  Discovery complete
      ├─ Device found → (silent success, UI unchanged)
      └─ Device NOT found → Auto-invalidate:
          ├─ Clear selectedChromecastName
          ├─ Radio → "Chromecast (none)"
          ├─ selectedOutput → .mpv
          └─ Save TOML
```

### Modal Open (Boot Still Running)
```
User clicks "Select Chromecast..." at T+2s
  ↓
Check discoveryState
  ├─ .scanning → Show spinner in modal
  │              Wait for completion
  │              When done → populate list
  │
  ├─ .completed → Show results immediately
  │               (no network call!)
  │
  └─ .idle → Start new discovery
              Show spinner
              Populate when done
```

### Modal Open (Boot Completed)
```
User clicks "Select Chromecast..." at T+10s
  ↓
Check discoveryState
  └─ .completed(devices, timestamp)
      → Show results immediately
      → Display "Last scanned: 8s ago"
      → "Rescan" button available
```

### Rescan Flow
```
User clicks "Rescan" button
  ↓
Check discoveryState
  ├─ .scanning → (Already running, just wait)
  └─ .idle or .completed → Start new scan
      ├─ discoveryState = .scanning
      ├─ Show spinner in modal
      ├─ Run discovery
      └─ Update list when complete
```

## Component Design

### TermKitTranscoderUI Changes

**New Properties:**
```swift
private var discoveryState: DiscoveryState = .idle
private var discoveryLock = NSLock()  // Thread-safe state access
```

**New Methods:**
```swift
private func startBackgroundDiscovery()
private func handleDiscoveryComplete(devices: [ChromecastDevice])
private func autoInvalidateConfiguredDevice(devices: [ChromecastDevice])
```

**Modified Methods:**
- `run()`: Trigger background discovery after UI init
- `presentDiscovery()`: Check state, reuse if available
- `showDiscoveryDialog()`: Add "Rescan" button, show timestamp

### Thread Safety

**Discovery state is accessed from multiple threads:**
- Main thread: UI updates, state checks
- Background thread: Discovery completion

**Solution: NSLock or DispatchQueue**
```swift
private let discoveryQueue = DispatchQueue(label: "com.beamy.discovery", qos: .userInitiated)

private var _discoveryState: DiscoveryState = .idle
private var discoveryState: DiscoveryState {
    get { discoveryQueue.sync { _discoveryState } }
    set { discoveryQueue.sync { _discoveryState = newValue } }
}
```

## Auto-Invalidation Logic

```swift
func autoInvalidateConfiguredDevice(devices: [ChromecastDevice]) {
    guard let configured = selectedChromecastName else {
        // No device configured, nothing to invalidate
        return
    }

    let exists = devices.contains(where: { $0.name == configured })

    if !exists {
        log("Background discovery: '\(configured)' not found - auto-invalidating")

        // Update all three representations on main thread
        DispatchQueue.main.async {
            self.selectedChromecastName = nil
            self.selectedOutput = .mpv
            self.config.chromecast.defaultDevice = nil
            try? self.config.save()
            self.rebuildOutputRadio(chromecastName: nil, selected: OutputChoice.mpv.rawValue, statusLabel: nil)
        }
    }
}
```

## Modal Integration

**Before (current):**
```swift
func presentDiscovery() {
    showSpinner()
    ChromecastDiscovery.discover() { devices in
        hideSpinner()
        showDiscoveryDialog(devices)
    }
}
```

**After (with shared state):**
```swift
func presentDiscovery() {
    switch discoveryState {
    case .scanning:
        // Already running - just show spinner and wait
        showSpinner()
        waitForDiscoveryCompletion { devices in
            hideSpinner()
            showDiscoveryDialog(devices)
        }

    case .completed(let devices, _):
        // Use cached results
        showDiscoveryDialog(devices)

    case .idle:
        // Start new discovery
        startDiscovery { devices in
            showDiscoveryDialog(devices)
        }
    }
}
```

## Rescan Button Implementation

```swift
// In showDiscoveryDialog():

let rescanButton = Button("Rescan")
rescanButton.clicked = { [weak self] in
    guard let self else { return }

    // Reset state to trigger new scan
    self.discoveryState = .idle

    // Start fresh discovery
    self.startDiscovery { devices in
        // Update the already-open modal's list
        self.updateDiscoveryList(devices)
    }

    // Show spinner while scanning
    self.showSpinnerInModal()
}
```

## Edge Cases

### Case 1: User Opens Modal During Boot Discovery
```
T+0s: Boot, start background discovery
T+2s: User clicks "Select Chromecast..."
      → discoveryState == .scanning
      → Show spinner in modal
      → Wait for boot discovery to complete
      → Reuse results (no duplicate scan!)
```

### Case 2: User Clicks Rescan While Scan Running
```
State: .scanning
User clicks "Rescan"
  → No-op or show "Already scanning..."
  → Just wait for current scan to complete
```

### Case 3: Discovery Timeout During Boot
```
Background discovery times out (no devices found)
  → discoveryState = .completed([], Date())
  → Auto-invalidate configured device
  → Clear config, revert to mpv
```

### Case 4: Network Changes During App Runtime
```
OUT OF SCOPE for this change
Future: Could listen to network reachability
        and trigger fresh discovery
```

## Performance Considerations

**Boot Time:**
- UI appears instantly (no blocking)
- Discovery runs in background (2-5 seconds)
- Main thread only touched for state updates

**Memory:**
- `DiscoveryState` holds array of `ChromecastDevice`
- Typical: 1-5 devices, ~1KB total
- Acceptable overhead

**Network:**
- One discovery per boot (acceptable)
- User can manually refresh via "Rescan"
- No automatic polling (would waste battery/network)

## Migration Path

**Phase 1: Add Shared State**
- Add `DiscoveryState` enum and property
- No behavior change yet

**Phase 2: Background Discovery on Boot**
- Trigger discovery in `run()`
- Add auto-invalidation logic

**Phase 3: Modal Integration**
- Check state before discovering
- Show cached results if available

**Phase 4: Rescan Button**
- Add button to modal
- Wire up to trigger fresh discovery

**Phase 5: UI Polish**
- Show "Last scanned: Xs ago"
- Spinner improvements
- Status messages
