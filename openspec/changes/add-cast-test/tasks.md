## 1. Implementation
- [x] 1.1 Create StaticFileServer class in Sources/Beamster/Server/
- [x] 1.2 Create CastTest command in Sources/Beamster/Commands/
- [x] 1.3 Register CastTest in Beamster.swift subcommands
- [x] 1.4 Test with actual Chromecast device (Bedroom TV)
  - Fixed: Replaced DIAL protocol (port 8008) with Cast V2 protocol (TLS on port 8009)
  - Created CastV2Client.swift with proper protobuf framing
  - Successfully displays "Beamy McBeamface" test image on Chromecast
