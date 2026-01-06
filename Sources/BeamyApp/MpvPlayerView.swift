import SwiftUI
import AppKit
import OpenGL.GL
import OpenGL.GL3
import Libmpv
import Foundation

// NOTE: Embedded mpv playback is currently disabled (useEmbeddedPlayer = false in CastingViewModel)
// because NSOpenGLView embedded in SwiftUI causes crashes during window activation.
// The crash happens in AppKit theming code (_CUIThemeFacetCacheKey) when the window
// gains focus. This is a known limitation of embedding NSOpenGLView in SwiftUI.
// Future options: Use Metal instead of OpenGL, or use a separate window for video.

private let logFile = "/tmp/beamy-mpv.log"

private func mpvLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

// Free function for C callback - can't capture Self
private func mpvGetProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
    let symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    let identifier = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    return CFBundleGetFunctionPointerForName(identifier, symbolName)
}

// MARK: - Notification names for mpv events (decouples from @MainActor types)
private extension Notification.Name {
    static let mpvNeedsDisplay = Notification.Name("mpvNeedsDisplay")
    static let mpvPositionChanged = Notification.Name("mpvPositionChanged")
    static let mpvDurationChanged = Notification.Name("mpvDurationChanged")
    static let mpvPausedChanged = Notification.Name("mpvPausedChanged")
    static let mpvPlaybackEnded = Notification.Name("mpvPlaybackEnded")
}

// MARK: - Callback Context (completely isolated from @MainActor types)
// Uses NotificationCenter to signal events - no closures that could capture actor-isolated types
private final class MpvCallbackContext: @unchecked Sendable {
    let mpv: OpaquePointer
    let queue: DispatchQueue
    let viewId: ObjectIdentifier  // Use ID instead of view reference

    init(mpv: OpaquePointer, queue: DispatchQueue, viewId: ObjectIdentifier) {
        self.mpv = mpv
        self.queue = queue
        self.viewId = viewId
    }

    func triggerDisplay() {
        // Post notification - no actor-isolated types referenced
        NotificationCenter.default.post(name: .mpvNeedsDisplay, object: nil, userInfo: ["viewId": viewId])
    }

    func processEvents() {
        let eventMpv = mpv
        let vid = viewId

        queue.async {
            while true {
                let event = mpv_wait_event(eventMpv, 0)
                guard let eventPtr = event else { break }

                if eventPtr.pointee.event_id == MPV_EVENT_NONE {
                    break
                }

                switch eventPtr.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let data = eventPtr.pointee.data else { break }
                    let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    let name = String(cString: property.name)
                    guard property.data != nil else { break }

                    switch name {
                    case "time-pos":
                        let value = property.data.assumingMemoryBound(to: Double.self).pointee
                        NotificationCenter.default.post(name: .mpvPositionChanged, object: nil, userInfo: ["viewId": vid, "value": value])
                    case "duration":
                        let value = property.data.assumingMemoryBound(to: Double.self).pointee
                        NotificationCenter.default.post(name: .mpvDurationChanged, object: nil, userInfo: ["viewId": vid, "value": value])
                    case "pause":
                        let value = property.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        NotificationCenter.default.post(name: .mpvPausedChanged, object: nil, userInfo: ["viewId": vid, "value": value])
                    case "eof-reached":
                        let value = property.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        if value {
                            NotificationCenter.default.post(name: .mpvPlaybackEnded, object: nil, userInfo: ["viewId": vid])
                        }
                    default:
                        break
                    }

                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = eventPtr.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                        let prefix = String(cString: msg.prefix)
                        let level = String(cString: msg.level)
                        let text = String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        mpvLog("MPV[\(prefix)/\(level)]: \(text)")
                    }

                case MPV_EVENT_END_FILE:
                    NotificationCenter.default.post(name: .mpvPlaybackEnded, object: nil, userInfo: ["viewId": vid])

                case MPV_EVENT_SHUTDOWN:
                    mpvLog("MPV shutdown event")
                    return

                default:
                    break
                }
            }
        }
    }
}

// MARK: - MPV OpenGL View (based on MPVKit demo)

final class MpvOpenGLView: NSOpenGLView {
    private var mpv: OpaquePointer?
    private var mpvGL: OpaquePointer?
    private var defaultFBO: GLint = -1
    private var queue = DispatchQueue(label: "mpv", qos: .userInteractive)
    private(set) var isSetupComplete = false
    private var callbackContext: MpvCallbackContext?
    private var notificationObservers: [Any] = []

    // Callbacks for state changes
    var onPositionChanged: ((TimeInterval) -> Void)?
    var onDurationChanged: ((TimeInterval) -> Void)?
    var onPausedChanged: ((Bool) -> Void)?
    var onPlaybackEnded: (() -> Void)?

    override class func defaultPixelFormat() -> NSOpenGLPixelFormat {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), NSOpenGLPixelFormatAttribute(32),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), NSOpenGLPixelFormatAttribute(24),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAStencilSize), NSOpenGLPixelFormatAttribute(8),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAMultisample),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFASampleBuffers), NSOpenGLPixelFormatAttribute(1),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFASamples), NSOpenGLPixelFormatAttribute(4),
            NSOpenGLPixelFormatAttribute(0)
        ]
        return NSOpenGLPixelFormat(attributes: attributes)!
    }

    override init?(frame frameRect: NSRect, pixelFormat format: NSOpenGLPixelFormat?) {
        super.init(frame: frameRect, pixelFormat: format ?? Self.defaultPixelFormat())
        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setupContext() {
        autoresizingMask = [.width, .height]
        openGLContext?.makeCurrentContext()
        mpvLog("OpenGL context setup complete")
    }

    func setupMpv() {
        guard !isSetupComplete else {
            mpvLog("setupMpv already complete")
            return
        }

        mpv = mpv_create()
        guard mpv != nil else {
            mpvLog("Failed to create mpv context")
            return
        }
        mpvLog("mpv created")

        // Configure mpv
        checkError(mpv_request_log_messages(mpv, "v"))
        checkError(mpv_set_option_string(mpv, "hwdec", "auto-safe"))
        checkError(mpv_set_option_string(mpv, "vo", "libmpv"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        checkError(mpv_set_option_string(mpv, "idle", "yes"))

        checkError(mpv_initialize(mpv))
        mpvLog("mpv initialized")

        // Setup OpenGL render context
        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: mpvGetProcAddress,
            get_proc_address_ctx: nil
        )

        // Create callback context BEFORE setting up callbacks
        // This context uses ObjectIdentifier instead of any @MainActor reference
        let viewId = ObjectIdentifier(self)
        let context = MpvCallbackContext(mpv: mpv!, queue: queue, viewId: viewId)
        self.callbackContext = context

        // Set up notification observers on main thread to handle events
        setupNotificationObservers(viewId: viewId)

        withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPtr),
                mpv_render_param()
            ]

            let result = mpv_render_context_create(&mpvGL, mpv, &params)
            if result < 0 {
                mpvLog("Failed to initialize mpv GL context: \(String(cString: mpv_error_string(result)))")
                return
            }
            mpvLog("mpv GL context created successfully!")

            // Use callback context instead of view to avoid actor isolation issues
            mpv_render_context_set_update_callback(
                mpvGL,
                { ctx in
                    guard let ctx = ctx else { return }
                    let context = Unmanaged<MpvCallbackContext>.fromOpaque(ctx).takeUnretainedValue()
                    context.triggerDisplay()
                },
                UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
            )
        }

        // Observe properties
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 3, "eof-reached", MPV_FORMAT_FLAG)

        // Set wakeup callback for events using non-isolated context
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx = ctx else { return }
            let context = Unmanaged<MpvCallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            context.processEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque()))

        isSetupComplete = true
        mpvLog("mpv setup complete")
    }

    private func setupNotificationObservers(viewId: ObjectIdentifier) {
        // Observe notifications from the callback context
        // These run on main thread since we're adding them from main thread
        let displayObserver = NotificationCenter.default.addObserver(
            forName: .mpvNeedsDisplay, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let notifViewId = info["viewId"] as? ObjectIdentifier,
                  notifViewId == viewId else { return }
            self?.display()
        }

        let posObserver = NotificationCenter.default.addObserver(
            forName: .mpvPositionChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let notifViewId = info["viewId"] as? ObjectIdentifier,
                  notifViewId == viewId,
                  let value = info["value"] as? Double else { return }
            self?.onPositionChanged?(value)
        }

        let durObserver = NotificationCenter.default.addObserver(
            forName: .mpvDurationChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let notifViewId = info["viewId"] as? ObjectIdentifier,
                  notifViewId == viewId,
                  let value = info["value"] as? Double else { return }
            self?.onDurationChanged?(value)
        }

        let pauseObserver = NotificationCenter.default.addObserver(
            forName: .mpvPausedChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let notifViewId = info["viewId"] as? ObjectIdentifier,
                  notifViewId == viewId,
                  let value = info["value"] as? Bool else { return }
            self?.onPausedChanged?(value)
        }

        let endObserver = NotificationCenter.default.addObserver(
            forName: .mpvPlaybackEnded, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let notifViewId = info["viewId"] as? ObjectIdentifier,
                  notifViewId == viewId else { return }
            self?.onPlaybackEnded?()
        }

        notificationObservers = [displayObserver, posObserver, durObserver, pauseObserver, endObserver]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mpvGL = mpvGL else { return }

        // Clear background
        glClearColor(0, 0, 0, 0)
        glClear(UInt32(GL_COLOR_BUFFER_BIT))

        glGetIntegerv(UInt32(GL_FRAMEBUFFER_BINDING), &defaultFBO)

        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)

        var fbo = mpv_opengl_fbo(
            fbo: Int32(defaultFBO),
            w: Int32(dims[2]),
            h: Int32(dims[3]),
            internal_format: 0
        )

        var flip: CInt = 1
        withUnsafeMutablePointer(to: &flip) { flipPtr in
            withUnsafeMutablePointer(to: &fbo) { fboPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param()
                ]
                mpv_render_context_render(mpvGL, &params)
            }
        }

        openGLContext?.flushBuffer()
    }

    // MARK: - Playback Control

    func loadFile(_ url: URL) {
        guard let mpv = mpv else {
            mpvLog("loadFile: mpv not ready")
            return
        }

        mpvLog("Loading file: \(url.path)")
        command("loadfile", args: [url.absoluteString, "replace"])
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func togglePause() {
        command("cycle", args: ["pause"])
    }

    func seek(to time: TimeInterval) {
        command("seek", args: [String(format: "%.2f", time), "absolute"])
    }

    func seekRelative(_ seconds: Double) {
        command("seek", args: [String(format: "%.2f", seconds), "relative"])
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

    private func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv = mpv else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func command(_ command: String, args: [String] = []) {
        guard let mpv = mpv else { return }

        var cargs = [command] + args + [nil as String?]
        var cstrs = cargs.map { $0.flatMap { strdup($0) } }
        defer {
            for ptr in cstrs where ptr != nil {
                free(ptr)
            }
        }

        var ptrs = cstrs.map { $0.map { UnsafePointer($0) } }
        let result = mpv_command(mpv, &ptrs)
        if result < 0 {
            mpvLog("Command '\(command)' failed: \(String(cString: mpv_error_string(result)))")
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        mpvLog("Shutting down mpv...")

        // Remove notification observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []

        // Clear callback context first to stop callbacks
        callbackContext = nil

        if let mpvGL = mpvGL {
            mpv_render_context_free(mpvGL)
            self.mpvGL = nil
        }

        if let mpv = mpv {
            mpv_terminate_destroy(mpv)
            self.mpv = nil
        }

        mpvLog("mpv shutdown complete")
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            mpvLog("MPV error: \(String(cString: mpv_error_string(status)))")
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

    func makeNSView(context: Context) -> MpvOpenGLView {
        mpvLog("makeNSView called")
        let view = MpvOpenGLView(frame: .zero, pixelFormat: nil)!

        view.onPositionChanged = { position in
            DispatchQueue.main.async {
                currentTime = position
            }
        }

        view.onDurationChanged = { dur in
            DispatchQueue.main.async {
                duration = dur
            }
        }

        view.onPausedChanged = { paused in
            DispatchQueue.main.async {
                isPlaying = !paused
            }
        }

        context.coordinator.view = view
        onCoordinatorReady?(context.coordinator)

        // Setup mpv
        view.setupContext()
        view.setupMpv()

        // Load file if we have one
        if let url = url {
            context.coordinator.lastURL = url
            mpvLog("Loading initial file: \(url.lastPathComponent)")
            view.loadFile(url)
        }

        return view
    }

    func updateNSView(_ nsView: MpvOpenGLView, context: Context) {
        // Load file when URL changes
        if nsView.isSetupComplete, let url = url, context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            mpvLog("updateNSView: Loading file \(url.lastPathComponent)")
            nsView.loadFile(url)
        }
    }

    static func dismantleNSView(_ nsView: MpvOpenGLView, coordinator: Coordinator) {
        nsView.shutdown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
