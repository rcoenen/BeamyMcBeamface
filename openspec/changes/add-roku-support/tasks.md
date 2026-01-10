# Tasks: Add Roku Support

## 0. Setup (Blocker)
- [x] 0.1 Add multicast entitlement to project
- [x] 0.2 Add NSLocalNetworkUsageDescription to Info.plist
- [ ] 0.3 Add NSBonjourServices for _roku._tcp (skipped - Roku uses SSDP, not Bonjour)

## 1. Device Model
- [x] 1.1 Create `RokuDevice.swift` with name, address, port, serialNumber
- [x] 1.2 Add Hashable/Equatable conformance

## 2. SSDP Discovery
- [x] 2.1 Create `RokuDiscovery.swift` with SSDP client
- [x] 2.2 Implement M-SEARCH multicast to 239.255.255.250:1900
- [x] 2.3 Parse LOCATION header from responses
- [x] 2.4 Fetch device info from /query/device-info
- [x] 2.5 Add timeout and error handling

## 3. ECP Player
- [x] 3.1 Create `RokuPlayer.swift` with cast() method
- [x] 3.2 Implement POST to /input/15985 with video URL
- [x] 3.3 Add playback controls (play, pause, stop)
- [x] 3.4 Add sendKey() for Fwd/Rev/Back

## 4. UI Integration
- [x] 4.1 Add RokuSelectorView (similar to ChromecastSelectorView)
- [x] 4.2 Update CastingViewModel to handle Roku devices
- [x] 4.3 Wire up Roku player to playback controls
- [x] 4.4 Update ContentView with Roku output option

## 5. Error Handling
- [x] 5.1 Handle discovery timeout (3s) → "No devices found"
- [x] 5.2 Handle cast failure → error toast, keep local playback
- [ ] 5.3 Handle network permission denied → prompt message

## 6. Testing
- [ ] 6.1 Test discovery on network with Roku device
- [ ] 6.2 Test HLS playback from TranscodeServer
- [ ] 6.3 Test playback controls
- [ ] 6.4 Test with network permission denied
