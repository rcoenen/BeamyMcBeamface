# Project Context

## Purpose
Beamy McBeamface is a macOS application for casting video files to Chromecast devices or playing locally. It transcodes video on-the-fly using FFmpeg to HLS format for seamless streaming. The app provides a simple drag-and-drop interface with playback controls, device discovery, and a menu bar extra for quick access.

## Tech Stack
- **Language:** Swift 6.0 with strict concurrency
- **UI Framework:** SwiftUI (macOS 13+)
- **Build System:** Swift Package Manager + XcodeGen (`project.yml` generates Xcode project)
- **Transcoding:** FFmpeg (external binary, HLS output)
- **Configuration:** TOML via TOMLKit
- **Protocols:** Cast V2 (protobuf-based Chromecast protocol), mDNS/Bonjour for device discovery

## Project Conventions

### Code Style
- Swift standard naming conventions (camelCase for properties/methods, PascalCase for types)
- Prefer `async/await` and Swift concurrency where appropriate
- Use `@unchecked Sendable` sparingly for legacy thread-safe types
- Keep SwiftUI views focused; extract complex logic into ViewModels
- Logging to `/tmp/beamy-*.log` for debugging

### Architecture Patterns
- **MVVM:** SwiftUI views with `@StateObject`/`@EnvironmentObject` ViewModels
- **Protocol-oriented:** `Player` protocol abstracts playback backends (mpv, Chromecast)
- **Modular:** `BeamyKit` library contains core logic; `BeamyApp` is the SwiftUI application
- **Server components:** `TranscodeServer`, `ImageServer`, `StaticFileServer` for streaming infrastructure

### Testing Strategy
- No automated tests currently (Tests directory removed)
- Manual testing via drag-and-drop and Chromecast device verification

### Git Workflow
- Feature branches merged into main
- XcodeGen-generated `.xcodeproj` is gitignored; regenerate from `project.yml`
- AI assistant directories (`.claude/`, `.gemini/`, `openspec/`) are gitignored

## Domain Context
- **Beaming:** European term for projecting/streaming content ("beamer" = projector)
- **HLS:** HTTP Live Streaming - adaptive bitrate protocol; Chromecast requires this or DASH
- **Cast V2:** Google's proprietary protocol using TLS + Protocol Buffers over TCP
- **Default Media Receiver:** Generic Chromecast app (ID: `CC1AD845`) that plays standard media URLs
- **Transcoding:** Converting video formats on-the-fly; needed because Chromecast has limited codec support

## Important Constraints
- **macOS only:** No iOS/tvOS support planned
- **Chromecast codec limitations:** Must transcode most formats to H.264/AAC in fMP4/HLS
- **Network access required:** App needs server (for transcoding) and client (for Chromecast) network permissions
- **No App Sandbox:** Hardened runtime disabled due to FFmpeg subprocess and network server requirements
- **FFmpeg dependency:** External binary must be installed (typically via Homebrew)

## External Dependencies
- **FFmpeg:** Video transcoding (must be installed separately)
- **mpv:** Local video playback backend (optional, for non-embedded mode)
- **TOMLKit:** TOML configuration parsing (Swift Package)
- **Chromecast devices:** Target hardware for casting functionality
