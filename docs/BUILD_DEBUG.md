# Build & Debug

## Build

**Release build** (recommended for testing):
```sh
xcodebuild -scheme BeamyMcBeamface -configuration Release -derivedDataPath .build/DerivedData build
```

**Debug build**:
```sh
xcodebuild -scheme BeamyMcBeamface -configuration Debug -derivedDataPath .build/DerivedData build
```

> **Note:** This project uses xcodebuild, not `swift build`. The `-derivedDataPath .build/DerivedData` flag keeps build artifacts in the project directory.

## Run the Latest Build

**Release**:
```sh
open ".build/DerivedData/Build/Products/Release/Beamy McBeamface.app"
```

**Debug**:
```sh
open ".build/DerivedData/Build/Products/Debug/Beamy McBeamface.app"
```

## Debug Notes

- Transcoder log: `~/Library/Logs/BeamyMcBeamface.transcoder.log`
- Main app log (if present): `~/Library/Logs/BeamyMcBeamface.log`

## Debug Steps (Xcode)

1) Open `BeamyMcBeamface.xcodeproj` in Xcode.
2) Select the `BeamyMcBeamface` scheme and a macOS destination.
3) Press Run (or `Cmd+R`).
4) Set breakpoints in:
   - UI: `Sources/BeamyApp/`
   - Transcoder/server: `Sources/BeamyKit/FFmpeg/`
5) Use Xcode’s Debug Area to inspect logs and variable values.

## Debug Steps (Attach to Running App)

1) Run the app normally (see "Run the Latest Build").
2) In Xcode: Debug > Attach to Process > `Beamy McBeamface`.
3) Set breakpoints and reproduce the issue.

## Read the Logs

Tail live:

```sh
tail -f ~/Library/Logs/BeamyMcBeamface.transcoder.log
```

Last 80 lines:

```sh
tail -n 80 ~/Library/Logs/BeamyMcBeamface.transcoder.log
```

Filter recent system logs:

```sh
/usr/bin/log show --last 5m --predicate 'process == "Beamy McBeamface"' --style compact
```
