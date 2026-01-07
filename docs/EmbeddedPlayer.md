# Embedded mpv Player - Technical Notes

## Current Status: Disabled

Embedded mpv playback is **disabled** (`useEmbeddedPlayer = false` in `CastingViewModel.swift`) due to crashes when the window gains focus.

## The Problem

When embedding `NSOpenGLView` (used by mpv for OpenGL rendering) inside a SwiftUI view hierarchy via `NSViewRepresentable`, the app crashes during window activation.

### Crash Details

```
Exception Type:  EXC_BREAKPOINT (SIGTRAP)
Faulting Thread: 0 (main thread)

Stack trace:
0  _CUIThemeFacetCacheKey isEqual:
1  -[NSArray indexOfObject:]
2  +[CUIThemeFacet _facetWithKeyList:...]
...
14 -[NSVisualEffectView _windowChangedKeyState]
...
27 -[NSApplication _handleActivatedEvent:]
```

The crash occurs in AppKit's Core UI theming system when:
1. The window receives focus (`_handleActivatedEvent:`)
2. AppKit traverses the view hierarchy to update visual effects
3. It encounters the `NSOpenGLView` and crashes in `_CUIThemeFacetCacheKey isEqual:`

### Root Cause

This appears to be a compatibility issue between:
- **NSOpenGLView** - Apple's legacy OpenGL view class
- **SwiftUI's NSViewRepresentable** - The bridge for embedding AppKit views
- **AppKit's theming system** - Specifically visual effect views and window key state

The `NSOpenGLView` doesn't properly participate in AppKit's modern theming infrastructure when embedded in SwiftUI, causing a crash when the system tries to query theme-related properties.

## Implementation Details

### Files Involved

| File | Purpose |
|------|---------|
| `MpvPlayerView.swift` | SwiftUI wrapper and NSOpenGLView implementation |
| `CastingViewModel.swift` | Contains `useEmbeddedPlayer` flag |
| `ContentView.swift` | Conditionally shows embedded player |

### How It Was Supposed to Work

```swift
// In ContentView.swift
if viewModel.useEmbeddedPlayer && viewModel.outputType == .mpv {
    MpvPlayerView(
        url: viewModel.currentFile,
        isPlaying: $viewModel.embeddedIsPlaying,
        currentTime: $viewModel.embeddedCurrentTime,
        duration: $viewModel.embeddedDuration,
        onCoordinatorReady: { coordinator in
            viewModel.embeddedPlayerCoordinator = coordinator
        }
    )
}
```

### Architecture

```
┌─────────────────────────────────────────────────┐
│ SwiftUI                                         │
│  ┌─────────────────────────────────────────┐   │
│  │ MpvPlayerView (NSViewRepresentable)     │   │
│  │  ┌─────────────────────────────────┐    │   │
│  │  │ MpvOpenGLView (NSOpenGLView)    │    │   │  ← Crash here
│  │  │  - OpenGL context               │    │   │
│  │  │  - mpv render context           │    │   │
│  │  └─────────────────────────────────┘    │   │
│  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

## Potential Solutions

### 1. AVPlayer consuming the transcoder stream (Recommended)

**Key insight**: Run the transcoder for every dropped file and have the embedded AVPlayer load the transcoder stream URL (the same URL Chromecast uses). One stream, two outputs; no external player.

```swift
import AVKit
import SwiftUI

struct EmbeddedAVPlayerView: View {
    let streamURL: URL  // http://localhost:PORT/...
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: streamURL))
                player.play()
            }
    }
}
```

**Pros:**
- Native SwiftUI support via `VideoPlayer`
- One transcoder stream powers both embedded playback and Chromecast
- No crash issues - Apple's own framework
- Consistent behavior regardless of source format
- Proper system integration (AirPlay, Picture-in-Picture, etc.)

**Cons:**
- Transcoder output must be AVPlayer-compatible (e.g., HLS/fMP4)
- Requires transcoder running even for local preview

**Status**: ✅ **Best option** - implement embedded playback against the transcoder stream; remove external player paths.

---

### 2. MPVKit Metal (Experimental)

MPVKit has **experimental** Metal support via a patch ([mpv PR #7857](https://github.com/mpv-player/mpv/pull/7857)).

> **Warning**: "Metal support only a patch version (#7857) and does not officially support it yet. Encountering any issues is not strange." - MPVKit README

The Metal path uses:
- **MoltenVK** - Vulkan-to-Metal translation layer
- **libplacebo** - High-performance video rendering

```swift
// Hypothetical Metal implementation
class MpvMetalView: NSView {
    override func makeBackingLayer() -> CALayer {
        return CAMetalLayer()
    }
}
```

**Status**: Experimental, may have issues. Worth trying but not guaranteed to work.

### 3. Separate Window for Video

Instead of embedding in SwiftUI, create a separate `NSWindow` for video:

```swift
class VideoWindow: NSWindow {
    let mpvView: MpvOpenGLView

    init() {
        // Create standalone window for video
        // SwiftUI controls in main window
        // Sync position/size between windows
    }
}
```

Pros:
- Avoids SwiftUI/AppKit integration issues
- Full control over the video window

Cons:
- Two separate windows to manage
- More complex window coordination

### 4. Use CAOpenGLLayer (Fixes the Crash)

**This directly addresses our crash.** The root cause is that **NSOpenGLView cannot be layer-backed**, but SwiftUI views ARE layer-backed by default. This mismatch causes the `_CUIThemeFacetCacheKey` theming crash.

[CAOpenGLLayer](https://developer.apple.com/documentation/quartzcore/caopengllayer) is designed for layer-backed contexts and should work in SwiftUI.

```swift
class MpvLayerBackedView: NSView {
    override var wantsLayer: Bool {
        get { true }
        set { }
    }

    override func makeBackingLayer() -> CALayer {
        return MpvOpenGLLayer()
    }
}

class MpvOpenGLLayer: CAOpenGLLayer {
    var mpvRenderContext: OpaquePointer?

    override func canDraw(inCGLContext ctx: CGLContextObj,
                          pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval,
                          displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        return true  // Always return true for mpv compatibility
    }

    override func draw(in ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLSetCurrentContext(ctx)
        // Call mpv_render_context_render() here
    }
}
```

**Pros:**
- Directly fixes the layer-backing crash
- Can have subviews (unlike NSOpenGLView)
- Keeps mpv's superior codec support and playback features
- Works with existing mpv render API code

**Cons:**
- OpenGL is deprecated since macOS 10.14 (still works, but no future)
- [CAOpenGLLayer has a timing issue with mpv](https://github.com/mpv-player/mpv/issues/5655): it "refuses to call its draw function when it thinks it's not needed" (minimized, different space), but mpv expects `mpv_render_context_render` called for every update callback. This can cause dropped frames and ~0.2s delays.
- Requires careful handling of the render loop

**Status**: 🔶 **Viable fallback** - Should fix the crash, but OpenGL is deprecated and has mpv timing quirks.

**Reference**: [mpv cocoa-rendergl example](https://github.com/mpv-player/mpv-examples/tree/master/libmpv) shows OpenGL integration.

---

### 5. Use CAMetalLayer (Future-Proof)

The modern replacement for CAOpenGLLayer. Works with layer-backed views and is Apple's recommended path.

```swift
class MpvMetalView: NSView {
    override var wantsLayer: Bool {
        get { true }
        set { }
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        return layer
    }
}
```

**Pros:**
- Future-proof (Apple's recommended graphics API)
- Better performance than OpenGL
- Layer-backed, works with SwiftUI
- No deprecation warnings

**Cons:**
- [MPVKit Metal support is experimental](https://github.com/mpvkit/MPVKit) (patch #7857, unofficial)
- More complex to integrate with mpv's render API
- May require MoltenVK (Vulkan-to-Metal translation)

**Status**: 🔶 **Research-quality** - Best long-term option but mpv Metal support is unstable.

---

### 6. Wait for Apple/MPVKit Updates

- OpenGL is deprecated on macOS since 10.14
- Future MPVKit versions may have better SwiftUI support
- Apple may fix the theming crash in future macOS versions

## Current Workaround

The app uses **external mpv** for local playback:

```swift
// CastingViewModel.swift
@Published var useEmbeddedPlayer: Bool = false  // Disabled due to crash

// When false, the app launches mpv as external process
// via MpvPlayer class in BeamyKit
```

This works reliably but means video plays in a separate mpv window rather than embedded in the app.

## Testing the Embedded Player

To test if future fixes work:

1. Change `useEmbeddedPlayer` to `true` in `CastingViewModel.swift`
2. Build and run the app
3. Drop a video file
4. Click away from the window and back (triggers window activation)
5. If it doesn't crash, the issue is fixed

## Related Issues

- [MPVKit GitHub](https://github.com/mpvkit/MPVKit) - Check for Metal support
- NSOpenGLView is deprecated since macOS 10.14
- Similar issues reported with other OpenGL views in SwiftUI

## Conclusion

Embedded mpv playback via NSOpenGLView doesn't work in SwiftUI because **NSOpenGLView cannot be layer-backed**, and SwiftUI views are layer-backed by default.

### Options Summary

| Option | Stability | Effort | Future-Proof |
|--------|-----------|--------|--------------|
| **1. AVPlayer consumes transcoder stream (single format for embedded + Chromecast)** | ✅ Stable | Medium | ✅ Yes |
| **2. MPVKit Metal** | ⚠️ Experimental | High | ✅ Yes |
| **3. Separate Window** | ✅ Stable | Medium | 🔶 Okay |
| **4. CAOpenGLLayer** | 🔶 Has quirks | Medium | ❌ Deprecated |
| **5. CAMetalLayer** | ⚠️ Experimental | High | ✅ Yes |
| **6. Wait** | N/A | None | Unknown |

### Recommendation

**Start with AVPlayer local playback + on-demand transcoder for Chromecast** (Option 1). AVPlayer is native SwiftUI, zero dependencies, and keeps local playback on the original file; start the transcoder only when casting.

**If mpv-specific features are needed** (codec support, advanced playback), try CAOpenGLLayer (Option 4) as it directly fixes the layer-backing crash, though OpenGL is deprecated.

**For long-term**, watch MPVKit Metal support maturity.
