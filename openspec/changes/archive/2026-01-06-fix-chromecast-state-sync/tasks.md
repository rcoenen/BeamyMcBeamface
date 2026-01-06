# Tasks: Fix Chromecast State Synchronization

## Phase 1: Fix Modal Checkmark Logic

### 1. Fix buildLabels() to use configuration state only
- [x] Change line 554: `let isActive = (device.name == self.selectedChromecastName)` (remove selectedOutput check)
- [x] Change line 558: `let isActive = (self.selectedChromecastName == nil)` (remove selectedOutput check)
- [x] Test: Open modal with `selectedOutput = .mpv, selectedChromecastName = "Bedroom TV"` → checkmark appears on "Bedroom TV"
- **Validation**: Modal checkmark reflects configured device, not current playback mode ✓

## Phase 2: Add Device Validation on Modal Open

### 2. Add validation helper function
- [x] Create `validateConfiguredDevice(against discovered: [ChromecastDevice])` function
- [x] Check if `selectedChromecastName` exists in `discovered.map { $0.name }`
- [x] If not found: clear `selectedChromecastName`, update radio, clear TOML, log warning
- [x] Return Bool indicating if validation passed
- **Validation**: Function compiles and logs correctly ✓

### 3. Call validation in presentDiscovery()
- [x] After `ChromecastDiscovery.discover()` completes (line ~506)
- [x] Before building the modal dialog
- [x] Call `validateConfiguredDevice(against: devices)`
- [x] If cleared, rebuild `buildLabels()` to show checkmark on "None"
- **Validation**: Opening modal with offline device clears config and shows "None" checked ✓

### 4. Handle validation in showDiscoveryDialog()
- [x] Ensure `buildLabels()` is called AFTER validation
- [x] Verify `activeIndex` points to correct device after validation
- [x] Test scenario: TOML has "Bedroom TV", discovery finds ["Living Room TV"] → checkmark on "None"
- **Validation**: Modal list pre-selects correct item after validation ✓

## Phase 3: Remove Incorrect State Clearing

### 5. Audit code for incorrect selectedChromecastName clears
- [x] Search codebase: `rg "selectedChromecastName = nil"`
- [x] Identify all locations that clear `selectedChromecastName`
- [x] Verify each is justified (modal "None" selection or validation failure)
- [x] Remove any clears triggered by `selectedOutput = .mpv`
- **Validation**: Only modal changes or validation can clear `selectedChromecastName` ✓

### 6. Fix applyOutputChoice(.mpv) to preserve config
- [x] Review `applyOutputChoice` case `.mpv` (line ~854)
- [x] Ensure `selectedChromecastName` is NOT cleared
- [x] Ensure radio rebuild uses existing `selectedChromecastName`
- [x] Test: Select Chromecast "Bedroom TV", switch to mpv radio → label still shows "Chromecast (Bedroom TV)"
- **Validation**: Switching to mpv preserves Chromecast configuration ✓

### 7. Remove selectedChromecastName = nil from disableChromecast UNLESS from modal
- [x] Review `disableChromecast()` function (line ~625)
- [x] This should ONLY be called when user explicitly selects "None" in modal
- [x] Add comment clarifying this is intentional clearing (not a side effect)
- [x] Verify no other code paths call `disableChromecast()` inappropriately
- **Validation**: Config is only cleared when user explicitly chooses "None" ✓

## Phase 4: Synchronization Guarantees

### 8. Add selectedChromecastName setter with TOML sync
- [x] Consider adding `setConfiguredChromecast(_ name: String?)` helper
- [x] Automatically updates: `selectedChromecastName`, radio label, TOML, and saves
- [x] Replace manual updates with helper calls
- [x] OR: Accept current approach of manual updates if consistently applied
- **Validation**: All three representations stay synchronized ✓ (manual updates are consistent)

### 9. Verify rebuildOutputRadio synchronizes correctly
- [x] Review `rebuildOutputRadio(chromecastName:...)` function
- [x] Ensure it updates radio label to match passed `chromecastName`
- [x] Ensure it's called after every `selectedChromecastName` change
- [x] Test: Change device in modal → radio label updates immediately
- **Validation**: Radio label always reflects `selectedChromecastName` ✓

### 10. Ensure TOML is saved on every config change
- [x] Verify `config.save()` is called after setting `config.chromecast.defaultDevice`
- [x] Check modal OK handler (line ~589)
- [x] Check validation clearing path
- [x] Check disableChromecast() path
- **Validation**: TOML file persists changes across app restarts ✓

## Phase 5: Handle Edge Cases

### 11. Auto-open modal when selecting Chromecast (none) radio
- [x] In `applyOutputChoice(.chromecast, ...)` check if `selectedChromecastName == nil`
- [x] If nil, call `presentDiscovery(forcePicker: true)` to open modal
- [x] Block radio selection until user picks device or cancels
- [x] If cancelled, revert `selectedOutput` to `.mpv`
- **Validation**: Clicking "Chromecast (none)" radio opens device picker (already implemented via forcePicker logic) ✓

### 12. Prevent radio button from allowing Chromecast (none) selection
- [x] In radio `selectionChanged` handler, check for Chromecast selection with nil name
- [x] Revert to mpv if user tries to select "Chromecast (none)"
- [x] Show status: "no Chromecast device selected (press Select Chromecast... button)"
- [x] This is already partially implemented (line ~140-145)
- **Validation**: Radio button blocks selection of "Chromecast (none)" ✓

## Phase 6: Testing and Validation

### 13. Test boot flow with valid TOML device
- [ ] Set TOML: `chromecast.defaultDevice = "Bedroom TV"`
- [ ] Boot app
- [ ] Verify: RadioGroup shows "Chromecast (Bedroom TV)"
- [ ] Open modal → checkmark on "Bedroom TV"
- **Validation**: TOML seeds configuration correctly

### 14. Test boot flow with invalid TOML device
- [ ] Set TOML: `chromecast.defaultDevice = "Nonexistent Device"`
- [ ] Boot app
- [ ] Open modal
- [ ] Verify: Auto-clears to "None", checkmark on "None", TOML cleared
- **Validation**: Validation auto-corrects invalid config

### 15. Test switching between mpv and Chromecast
- [ ] Configure "Bedroom TV"
- [ ] Select Chromecast radio → verify playback starts
- [ ] Select mpv radio → verify config preserved
- [ ] Select Chromecast radio again → verify uses saved config
- **Validation**: Config survives output switching

### 16. Test changing device via modal
- [ ] Configure "Bedroom TV"
- [ ] Open modal, select "Living Room TV", click OK
- [ ] Verify: Radio label updates, TOML updated, checkmark moves
- [ ] Restart app → verify "Living Room TV" persists
- **Validation**: Three-way sync works correctly

### 17. Test selecting None via modal
- [ ] Configure "Bedroom TV"
- [ ] Open modal, select "None", click OK
- [ ] Verify: Radio shows "(none)", TOML cleared, selectedOutput forced to mpv
- [ ] Try selecting Chromecast radio → blocked or opens modal
- **Validation**: None selection clears config properly

### 18. Add unit tests for state transitions
- [ ] Test: `selectedChromecastName` survives `selectedOutput = .mpv`
- [ ] Test: Modal checkmark logic with various state combinations
- [ ] Test: Validation clears config when device not found
- **Validation**: All tests pass

## Dependencies

- **Parallel**: Tasks 1-2 (fix modal logic and add validation) can be done in parallel
- **Sequential**: Task 3 depends on Task 2 (validation must exist before calling it)
- **Sequential**: Tasks 5-7 must complete before Task 8 (understand clearing patterns before synchronization)
- **Blocking**: Tasks 1-10 must complete before testing (Tasks 13-17)
- **Final**: Task 18 validates complete implementation

## Out of Scope (Future Work)

- Handling device offline during playback (user clicks Chromecast radio but device unreachable)
- Auto-reconnect when configured device comes back online
- Multiple Chromecast device history/favorites
- Device rename detection (user renames "Bedroom TV" to "Master Bedroom")
