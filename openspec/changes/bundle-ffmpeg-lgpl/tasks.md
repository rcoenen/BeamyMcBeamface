# Tasks: Bundle LGPL FFmpeg

## 1. Build FFmpeg
- [x] 1.1 Clone FFmpeg source (tag n7.1)
- [x] 1.2 Configure with LGPL-only flags + VideoToolbox
- [x] 1.3 Build static binaries for arm64
- [x] 1.4 Verify binary works and is LGPL (no GPL codecs)
- [x] 1.5 Test H.264 encoding via VideoToolbox

## 2. Bundle in App
- [x] 2.1 Create `bin/` directory in project
- [x] 2.2 Add ffmpeg and ffprobe binaries (19 MB each)
- [x] 2.3 Update project.yml to copy binaries to Contents/MacOS/
- [x] 2.4 Add bin/ to .gitignore (built during CI)

## 3. Update Code
- [x] 3.1 Update `findExecutable()` to check Bundle.main first
- [x] 3.2 Fall back to system paths if bundled not found
- [x] 3.3 Update TranscodeServer to use h264_videotoolbox encoder
- [x] 3.4 Update TranscodeServer to use aac_at audio encoder

## 4. Licensing Compliance
- [x] 4.1 Add FFmpeg attribution to Settings/About
- [x] 4.2 Add LICENSE-FFMPEG.txt to project
- [ ] 4.3 Document source code location in README

## 5. Build Automation
- [x] 5.1 Create script to build FFmpeg (scripts/build-ffmpeg.sh)
- [ ] 5.2 Add to GitHub Actions for releases
- [ ] 5.3 Test DMG creation with bundled binary
