# Proposal: Bundle LGPL FFmpeg with VideoToolbox

## Summary

Bundle a minimal, LGPL-compliant FFmpeg binary in the app so users don't need to install FFmpeg separately. Uses Apple VideoToolbox for H.264 encoding instead of GPL-licensed libx264.

## Motivation

Currently Beamy requires users to have FFmpeg installed via Homebrew. This creates:
- Poor first-run experience ("FFmpeg not found")
- Dependency on external package manager
- Can't distribute a self-contained DMG

## Approach

Build a minimal FFmpeg with:
- **VideoToolbox** for hardware H.264/HEVC encoding (Apple's encoder)
- **AudioToolbox** for AAC encoding
- **LGPL-only** libraries (no GPL codecs)
- **Static linking** for single portable binary

This is legally distributable without open-sourcing Beamy, requiring only:
1. Attribution in About box
2. Link to FFmpeg source code

## Scope

- Build minimal LGPL FFmpeg (~15-20 MB)
- Bundle in app's `Contents/MacOS/`
- Update code to prefer bundled binary over system
- Add license attribution
- Update build process for releases

## Out of Scope

- Replacing FFmpeg with native VideoToolbox APIs (future work)
- Building FFmpeg as a library (using CLI binary approach)
- Windows/Linux builds
