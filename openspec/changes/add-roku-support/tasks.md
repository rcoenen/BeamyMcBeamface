# Tasks: Add Roku Casting Support

## 1. Device Model
- [x] 1.1 Create `RokuDevice.swift` with name, address, port, model
- [x] 1.2 Add Hashable/Equatable conformance

## 2. SSDP Discovery
- [x] 2.1 Create `RokuDiscovery.swift` with SSDP client
- [x] 2.2 Implement M-SEARCH multicast to 239.255.255.250:1900
- [x] 2.3 Parse LOCATION header from responses
- [x] 2.4 Fetch device info from /query/device-info
- [x] 2.5 Add timeout and error handling

## 3. Setup Detection
- [x] 3.1 Add `checkECPEnabled()` - query device-info for ecp-setting-mode
- [x] 3.2 Add `checkWebVideoCasterInstalled()` - query apps for channel 259656
- [x] 3.3 Add `RokuError.webVideoCasterNotInstalled` with helpful message

## 4. Web Video Caster Protocol (Reverse Engineered)
- [x] 4.1 Update `RokuPlayer.swift` to use channel 259656 instead of 15985
- [x] 4.2 Implement `launchReceiver()` - POST /launch/259656
- [x] 4.3 Implement `cast()` with cmd=play&url=...&tit=...&media=video&fmt=hls
- [x] 4.4 Add format detection (hls, mp4, mkv)

## 5. Playback Controls
- [x] 5.1 Implement play/pause via POST /keypress/Play
- [x] 5.2 Implement fast forward via POST /keypress/Fwd
- [x] 5.3 Implement rewind via POST /keypress/Rev
- [x] 5.4 Implement stop via POST /keypress/Back

## 6. UI - Device Selector
- [x] 6.1 Create `RokuSelectorView.swift` with device list
- [x] 6.2 Show loading state during discovery
- [x] 6.3 Show empty state when no devices found
- [x] 6.4 Add rescan button

## 7. UI - Setup Guide Popup
- [ ] 7.1 Create `RokuSetupGuideView.swift` as a sheet/popup window
- [ ] 7.2 Show step-by-step instructions with checkmarks for completed steps
- [ ] 7.3 Step 1: Enable "Control by mobile apps" with path
- [ ] 7.4 Step 2: Enable "Network access" with path
- [ ] 7.5 Step 3: Install Web Video Caster Receiver with link/instructions
- [ ] 7.6 Add "Check Again" button to re-verify setup
- [ ] 7.7 Auto-dismiss when all checks pass

## 8. Integration
- [x] 8.1 Add Roku to OutputType enum
- [x] 8.2 Update CastingViewModel with Roku device state
- [x] 8.3 Update ContentView with Roku output option
- [x] 8.4 Wire RokuSelectorView to show on Roku button click
- [ ] 8.5 Show setup guide automatically when setup incomplete
- [ ] 8.6 Cast HLS stream when Roku selected and video dropped

## 9. Testing
- [x] 9.1 Test SSDP discovery finds Roku devices
- [x] 9.2 Test Web Video Caster protocol plays MP4
- [x] 9.3 Test Web Video Caster protocol plays HLS
- [x] 9.4 Test auto-launch from Home screen
- [x] 9.5 Test auto-switch from other apps (e.g., Netflix)
- [ ] 9.6 Test setup detection (ECP disabled scenario)
- [ ] 9.7 Test setup detection (receiver not installed scenario)
- [ ] 9.8 Test full flow: drop video → transcode → cast to Roku
