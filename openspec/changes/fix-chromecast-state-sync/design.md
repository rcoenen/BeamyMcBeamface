# Design: Chromecast State Synchronization

## Architectural Pattern

This follows the **Separated Configuration and Runtime State** pattern, commonly seen in:

- **Bluetooth Audio (macOS)**: You can have "AirPods Pro" configured as a known device while playing to "Built-in Speakers"
- **Printer Settings**: Default printer is configured separately from the current print job destination
- **Spotify Connect**: Available devices are configured/remembered independently of current playback device

## State Separation

```
┌─────────────────────────────────────────────────────────────┐
│                    Runtime State (Ephemeral)                 │
│  selectedOutput: OutputChoice? (.mpv or .chromecast)         │
│  - Which radio button has the filled circle (●)              │
│  - What is CURRENTLY playing                                 │
│  - Can switch without losing configuration                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ independent of
                              │
┌─────────────────────────────────────────────────────────────┐
│               Configuration State (Persistent)                │
│  selectedChromecastName: String?                             │
│  config.chromecast.defaultDevice: String?                    │
│  - Which Chromecast device is configured/preferred           │
│  - Survives switching between mpv and chromecast             │
│  - Synchronized to TOML file on every change                 │
└─────────────────────────────────────────────────────────────┘
```

## Three-Way Synchronization

**Single Source of Truth:** `selectedChromecastName` (in-memory Swift variable)

**Synchronized Views:**
1. **TOML File** (`config.chromecast.defaultDevice`)
   - Written on every change via `config.save()`
   - Read once on boot to seed `selectedChromecastName`

2. **RadioGroup Label** (`Chromecast (Bedroom TV)`)
   - Rebuilt via `rebuildOutputRadio()` on every change
   - Visual display of current configuration

3. **Discovery Modal Checkmark** (`✓ Bedroom TV`)
   - Computed in `buildLabels()` based on `selectedChromecastName`
   - Shows which device is configured (NOT which is playing)

## State Transitions

### Boot Flow
```
1. Read TOML → config.chromecast.defaultDevice = "Bedroom TV"
2. Seed in-memory → selectedChromecastName = "Bedroom TV"
3. Build radio label → "Chromecast (Bedroom TV)"
4. User opens modal → ✓ appears on "Bedroom TV"
```

### Change Device via Modal
```
1. User selects "Living Room TV" in modal, clicks OK
2. Update in-memory → selectedChromecastName = "Living Room TV"
3. Rebuild radio label → "Chromecast (Living Room TV)"
4. Write TOML → config.chromecast.defaultDevice = "Living Room TV"
5. Persist → config.save()
```

### Select "None" in Modal
```
1. User selects "None" in modal, clicks OK
2. Update in-memory → selectedChromecastName = nil
3. Rebuild radio label → "Chromecast (none)"
4. Clear TOML → config.chromecast.defaultDevice = nil
5. Force runtime → selectedOutput = .mpv (can't play to nothing)
6. Persist → config.save()
```

### Switch Output to mpv Radio Button
```
1. User clicks mpv radio button
2. Update runtime → selectedOutput = .mpv
3. Cleanup Chromecast player (if active)
4. PRESERVE → selectedChromecastName unchanged!
5. Radio label → still shows "Chromecast (Bedroom TV)"
```

## Validation Strategy

**Optimistic Loading (Boot):**
- Trust TOML value without network check
- Fast startup, no blocking discovery

**Lazy Validation (Modal Open):**
- Run discovery when user opens "Select Chromecast..." modal
- Check if configured device exists in discovered list
- If missing: auto-clear to "none" and sync all three sources

**Why Lazy?**
- Network discovery is slow (2-5 seconds)
- User might never use Chromecast (don't slow boot for everyone)
- User can re-select if device comes back online later

## Edge Case Handling

### Case 1: Configured Device Offline
```
Boot:
  TOML: "Bedroom TV"
  selectedChromecastName: "Bedroom TV"
  Radio: "Chromecast (Bedroom TV)"

User clicks "Select Chromecast...":
  Discovery finds: ["Living Room TV"]  (Bedroom TV not found!)

  Auto-correct:
    selectedChromecastName = nil
    Radio → "Chromecast (none)"
    TOML → defaultDevice = nil
    Modal → ✓ on "None"
```

### Case 2: User Switches to mpv, Then Back to Chromecast
```
State: selectedOutput = .chromecast, selectedChromecastName = "Bedroom TV"

User clicks mpv radio:
  selectedOutput = .mpv
  selectedChromecastName = "Bedroom TV" (UNCHANGED!)

Later, user clicks Chromecast radio:
  selectedOutput = .chromecast
  Launch Chromecast to "Bedroom TV" (preserved config!)
```

### Case 3: User Clicks Chromecast Radio but selectedChromecastName == nil
```
Radio shows:
  ○ mpv
  ○ Chromecast (none)  ← user clicks this

Response:
  Auto-open "Select Chromecast..." modal (force device selection)
  Block until user picks a device or cancels
  If cancelled: revert to mpv radio
```

## Invariants

**Must always be true:**
1. `selectedChromecastName` matches TOML `defaultDevice`
2. RadioGroup label displays `selectedChromecastName` (or "none")
3. Discovery modal checkmark is on device matching `selectedChromecastName` (or "None")
4. Switching `selectedOutput` to `.mpv` NEVER clears `selectedChromecastName`
5. Only "Select Chromecast..." button or validation failure can change `selectedChromecastName`

## Implementation Strategy

**Phase 1: Fix Modal Checkmark Logic**
- Change `buildLabels()` to ignore `selectedOutput`
- Use only `selectedChromecastName` for checkmarks

**Phase 2: Add Validation on Modal Open**
- Check discovered devices against `selectedChromecastName`
- Auto-clear if missing

**Phase 3: Remove Incorrect Clears**
- Audit code for places that clear `selectedChromecastName`
- Ensure only modal changes or validation can clear it

**Phase 4: Add Tests**
- Unit test state transitions
- Verify invariants hold
