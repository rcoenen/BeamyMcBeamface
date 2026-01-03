# Project Context

## Purpose
Beamster is a macOS command-line tool for casting media files to Chromecast devices with on-the-fly transcoding. It allows users to stream local video files (particularly MKV files) to their Chromecast by automatically transcoding them to compatible formats using FFmpeg.

Key features:
- Discover Chromecast devices on the local network
- Transcode media files on-the-fly to Chromecast-compatible formats
- Stream via local HTTP server
- Configure FFmpeg encoding settings via TOML config file

## Tech Stack
- **Language**: Swift 6.0
- **Platform**: macOS 13+ (Ventura)
- **Package Manager**: Swift Package Manager (SPM)
- **CLI Framework**: swift-argument-parser (1.3.0+)
- **Config Parser**: TOMLKit (0.5.0+)
- **External Tools**: FFmpeg and FFprobe (required runtime dependencies)

## Project Conventions

### Code Style
- **Naming**:
  - PascalCase for types (structs, classes, protocols, enums)
  - camelCase for properties, methods, and variables
  - Descriptive names that clearly indicate purpose
- **File Organization**:
  - One primary type per file, matching the filename
  - Group related functionality in feature-based directories
- **Swift Conventions**:
  - Use Swift 6.0 strict concurrency where appropriate
  - Prefer structs over classes when possible
  - Use Foundation types (URL, FileManager, etc.) for system interactions

### Architecture Patterns
- **Modular Structure**: Code organized by feature domain
  - `FFmpeg/`: Media transcoding and server logic
  - `Chromecast/`: Device discovery and casting protocol
  - `Config/`: TOML configuration management
  - `Commands/`: CLI command implementations
- **Command Pattern**: Each CLI command is a separate `ParsableCommand` struct
- **Dependency Injection**: External dependencies (FFmpeg paths, config) loaded at runtime
- **Error Handling**: Use `ValidationError` for user-facing errors in commands
- **Configuration**: TOML-based config file (`beamster.toml`) for user settings

### Testing Strategy
Currently, the project does not have a formal test suite. When adding tests:
- Use XCTest framework
- Unit tests for core logic (media info parsing, config loading)
- Integration tests for FFmpeg interaction
- Mock Chromecast devices for testing casting logic

### Git Workflow
- **CRITICAL: NEVER create git commits unless explicitly instructed by the user**
  - Do NOT automatically commit after completing tasks
  - Do NOT suggest commits without explicit user request
  - Only run `git add` and `git commit` when the user specifically asks for it
- Configuration file (`beamster.toml`) is gitignored (users copy from `beamster.toml.example`)
- Standard Swift build artifacts ignored (`.build/`, `.swiftpm/`, etc.)

## Domain Context

### Media Streaming & Chromecast
- **Chromecast Protocol**: Uses mDNS/Bonjour for device discovery
- **Media Formats**: Primarily targets MKV files but should support any FFmpeg-compatible format
- **Transcoding**: On-the-fly conversion to H.264 video + AAC audio for Chromecast compatibility
- **Streaming**: Local HTTP server serves transcoded media to Chromecast over the network

### FFmpeg Integration
- FFprobe analyzes source media (codecs, duration, streams)
- FFmpeg performs real-time transcoding
- Configurable encoding presets (ultrafast to veryslow) and quality (CRF)
- Audio bitrate configurable via config file

## Important Constraints
- **Platform**: macOS only (requires macOS 13+)
- **Runtime Dependencies**: Requires FFmpeg and FFprobe installed on system
  - Typically installed via Homebrew: `brew install ffmpeg`
  - Paths configurable in `beamster.toml`
- **Network**: Requires local network access for Chromecast discovery and streaming
- **Port Availability**: Needs available ports in configured range (default 8080-9000) for HTTP server

## External Dependencies
- **FFmpeg/FFprobe**: Media analysis and transcoding engine
  - Auto-detected from PATH or configured in TOML
  - Used for: media info extraction, format conversion, streaming preparation
- **Chromecast Devices**: Target playback devices on local network
  - Discovered via mDNS/Bonjour
  - Communicate via Chromecast protocol
- **Network**: Local network required for device discovery and media streaming
