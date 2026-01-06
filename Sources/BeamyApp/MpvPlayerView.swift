import SwiftUI
import AppKit
import OpenGL.GL
import OpenGL.GL3
import Clibmpv
import Foundation

private func mpvLog(_ message: String) {
    NSLog("[MpvPlayerView] %@", message)
}

// Silence OpenGL deprecation warnings - we need it for libmpv
// In future, could migrate to Metal via mpv's Metal render API

// MARK: - Embedded MPV Player using libmpv render API

/// NSOpenGLView that hosts embedded mpv video playback
@MainActor
final class MpvOpenGLView: NSOpenGLView {
    private var mpv: OpaquePointer?
    private var mpvRenderContext: OpaquePointer?
    private var displayLink: CVDisplayLink?
    nonisolated(unsafe) private var isShuttingDown = false
    private(set) var isSetupComplete = false

    // Callbacks for state changes
    var onPositionChanged: ((TimeInterval) -> Void)?
    var onDurationChanged: ((TimeInterval) -> Void)?
    var onPausedChanged: ((Bool) -> Void)?
    var onPlaybackEnded: (() -> Void)?

    override init?(frame frameRect: NSRect, pixelFormat format: NSOpenGLPixelFormat?) {
        // Create a pixel format for OpenGL 3.2 Core Profile
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 24,
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            0
        ]

        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attrs) else {
            return nil
        }

        super.init(frame: frameRect, pixelFormat: pixelFormat)

        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        // Note: shutdown() should be called before deinit via dismantleNSView
    }

    // MARK: - Setup

    func setup() {
        guard let context = openGLContext else {
            mpvLog("No OpenGL context")
            return
        }
        context.makeCurrentContext()
        mpvLog("OpenGL context ready")

        // Enable VSync
        var swapInterval: GLint = 1
        context.setValues(&swapInterval, for: .swapInterval)

        // Initialize mpv
        mpv = mpv_create()
        guard mpv != nil else {
            mpvLog("Failed to create mpv context")
            return
        }
        mpvLog("mpv created")

        // Configure mpv for embedded rendering
        checkError(mpv_set_option_string(mpv, "vo", "libmpv"))
        checkError(mpv_set_option_string(mpv, "hwdec", "auto-safe"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        checkError(mpv_set_option_string(mpv, "idle", "yes"))

        // Initialize mpv
        let initResult = mpv_initialize(mpv)
        if initResult < 0 {
            mpvLog("mpv_initialize failed: \(String(cString: mpv_error_string(initResult)))")
            return
        }
        mpvLog("mpv initialized")

        // Setup render context
        setupRenderContext()
        mpvLog("render context setup done, context: \(String(describing: self.mpvRenderContext))")

        // Start display link for rendering
        setupDisplayLink()

        // Observe property changes
        observeProperties()
        isSetupComplete = true
        mpvLog("setup complete")
    }

    private func setupRenderContext() {
        guard let mpv = mpv else { return }

        // Get proc address function
        let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name = name else { return nil }
            let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
            let bundleURL = CFURLCreateWithFileSystemPath(
                kCFAllocatorDefault,
                "/System/Library/Frameworks/OpenGL.framework" as CFString,
                CFURLPathStyle.cfurlposixPathStyle,
                true
            )
            guard let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL) else { return nil }
            return CFBundleGetFunctionPointerForName(bundle, symbol)
        }

        // Create OpenGL init params - must stay in scope during mpv_render_context_create
        var initParams = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil
        )

        // Build params and create context with pointers in scope
        withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: MPV_RENDER_API_TYPE_OPENGL)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initParamsPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]

            let result = mpv_render_context_create(&mpvRenderContext, mpv, &params)
            if result < 0 {
                print("Failed to create mpv render context: \(String(cString: mpv_error_string(result)))")
            }
        }

        // Set update callback
        if let renderContext = mpvRenderContext {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            mpv_render_context_set_update_callback(renderContext, { ctx in
                guard let ctx = ctx else { return }
                let view = Unmanaged<MpvOpenGLView>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    view.needsDisplay = true
                }
            }, selfPtr)
        }
    }

    private func setupDisplayLink() {
        // Skip display link - use mpv's update callback instead
        // The render context callback will trigger needsDisplay when frames are ready
        mpvLog("Display link setup skipped - using mpv update callback")
    }

    private func observeProperties() {
        guard let mpv = mpv else { return }

        // Observe playback position
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 3, "eof-reached", MPV_FORMAT_FLAG)

        // Start event polling on background queue
        Task.detached { [weak self] in
            await self?.eventLoop()
        }
    }

    private func eventLoop() async {
        while !isShuttingDown, let mpv = mpv {
            let event = mpv_wait_event(mpv, 0.1)
            guard event?.pointee.event_id != MPV_EVENT_NONE else { continue }

            switch event?.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let prop = event?.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee else { continue }
                await handlePropertyChange(prop)

            case MPV_EVENT_END_FILE:
                await MainActor.run { [weak self] in
                    self?.onPlaybackEnded?()
                }

            case MPV_EVENT_SHUTDOWN:
                return

            default:
                break
            }
        }
    }

    private func handlePropertyChange(_ prop: mpv_event_property) async {
        guard prop.data != nil else { return }
        let name = String(cString: prop.name)

        switch name {
        case "time-pos":
            let value = prop.data.assumingMemoryBound(to: Double.self).pointee
            await MainActor.run { [weak self] in
                self?.onPositionChanged?(value)
            }

        case "duration":
            let value = prop.data.assumingMemoryBound(to: Double.self).pointee
            await MainActor.run { [weak self] in
                self?.onDurationChanged?(value)
            }

        case "pause":
            let value = prop.data.assumingMemoryBound(to: Int32.self).pointee != 0
            await MainActor.run { [weak self] in
                self?.onPausedChanged?(value)
            }

        case "eof-reached":
            let value = prop.data.assumingMemoryBound(to: Int32.self).pointee != 0
            if value {
                await MainActor.run { [weak self] in
                    self?.onPlaybackEnded?()
                }
            }

        default:
            break
        }
    }

    // MARK: - Rendering

    func render() {
        guard !isShuttingDown,
              let context = openGLContext,
              let renderContext = mpvRenderContext else { return }

        context.makeCurrentContext()

        let size = convertToBacking(bounds.size)
        var fbo = mpv_opengl_fbo(
            fbo: 0,
            w: Int32(size.width),
            h: Int32(size.height),
            internal_format: 0
        )

        var flipY: Int32 = 1

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }

        context.flushBuffer()
    }

    override func draw(_ dirtyRect: NSRect) {
        render()
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    // MARK: - Playback Control

    func loadFile(_ url: URL) {
        guard let mpv = mpv else {
            mpvLog("loadFile called but mpv is nil")
            return
        }
        let path = url.path
        mpvLog("Loading file: \(path)")

        // Build command: loadfile <path> replace
        path.withCString { pathPtr in
            "replace".withCString { replacePtr in
                "loadfile".withCString { cmdPtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, pathPtr, replacePtr, nil]
                    let result = mpv_command(mpv, &args)
                    if result < 0 {
                        mpvLog("loadfile failed: \(String(cString: mpv_error_string(result)))")
                    } else {
                        mpvLog("loadfile command sent successfully")
                    }
                }
            }
        }
    }

    func play() {
        guard let mpv = mpv else { return }
        var flag: Int32 = 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func pause() {
        guard let mpv = mpv else { return }
        var flag: Int32 = 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func togglePause() {
        guard let mpv = mpv else { return }

        "cycle".withCString { cmdPtr in
            "pause".withCString { pausePtr in
                var args: [UnsafePointer<CChar>?] = [cmdPtr, pausePtr, nil]
                mpv_command(mpv, &args)
            }
        }
    }

    func seek(to time: TimeInterval) {
        guard let mpv = mpv else { return }
        let timeStr = String(format: "%.2f", time)

        "seek".withCString { cmdPtr in
            timeStr.withCString { timePtr in
                "absolute".withCString { absPtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, timePtr, absPtr, nil]
                    mpv_command(mpv, &args)
                }
            }
        }
    }

    func seekRelative(_ seconds: Double) {
        guard let mpv = mpv else { return }
        let secStr = String(format: "%.2f", seconds)

        "seek".withCString { cmdPtr in
            secStr.withCString { secPtr in
                "relative".withCString { relPtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, secPtr, relPtr, nil]
                    mpv_command(mpv, &args)
                }
            }
        }
    }

    func getPosition() -> TimeInterval {
        guard let mpv = mpv else { return 0 }
        var position: Double = 0
        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
        return position
    }

    func getDuration() -> TimeInterval {
        guard let mpv = mpv else { return 0 }
        var duration: Double = 0
        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
        return duration
    }

    func isPaused() -> Bool {
        guard let mpv = mpv else { return true }
        var paused: Int32 = 0
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        return paused != 0
    }

    // MARK: - Cleanup

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }

        if let renderContext = mpvRenderContext {
            mpv_render_context_free(renderContext)
            mpvRenderContext = nil
        }

        if let mpv = mpv {
            mpv_terminate_destroy(mpv)
            self.mpv = nil
        }
    }

    private func checkError(_ status: Int32) {
        if status < 0 {
            print("mpv error: \(String(cString: mpv_error_string(status)))")
        }
    }
}

// MARK: - SwiftUI Wrapper

struct MpvPlayerView: NSViewRepresentable {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    var onSeek: ((TimeInterval) -> Void)?
    var onCoordinatorReady: ((Coordinator) -> Void)?

    @MainActor
    func makeNSView(context: Context) -> MpvOpenGLView {
        mpvLog("makeNSView called")
        let view = MpvOpenGLView(frame: .zero, pixelFormat: nil)!

        view.onPositionChanged = { position in
            currentTime = position
        }

        view.onDurationChanged = { dur in
            duration = dur
        }

        view.onPausedChanged = { paused in
            isPlaying = !paused
        }

        context.coordinator.view = view

        // Notify that coordinator is ready
        onCoordinatorReady?(context.coordinator)

        // Track initial URL
        if let url = url {
            context.coordinator.lastURL = url
            mpvLog("Initial URL set: \(url.lastPathComponent)")
        }

        // Setup immediately
        mpvLog("Calling setup...")
        view.setup()
        mpvLog("Setup returned")

        // Load file if we have one
        if let url = context.coordinator.lastURL {
            mpvLog("Loading initial file...")
            view.loadFile(url)
        }

        return view
    }

    @MainActor
    func updateNSView(_ nsView: MpvOpenGLView, context: Context) {
        // Load file when URL changes (only after setup is complete)
        if nsView.isSetupComplete, let url = url, context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            nsView.loadFile(url)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: MpvOpenGLView, coordinator: Coordinator) {
        nsView.shutdown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator {
        var view: MpvOpenGLView?
        var lastURL: URL?

        func play() {
            view?.play()
        }

        func pause() {
            view?.pause()
        }

        func togglePause() {
            view?.togglePause()
        }

        func seek(to time: TimeInterval) {
            view?.seek(to: time)
        }

        func seekRelative(_ seconds: Double) {
            view?.seekRelative(seconds)
        }
    }
}
