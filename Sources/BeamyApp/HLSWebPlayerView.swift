import SwiftUI
import WebKit

private func debugLog(_ message: String) {
    let msg = "[\(Date())] \(message)\n"
    let path = "/tmp/beamy-webview-debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: msg.data(using: .utf8))
    }
    print(message)
}

/// SwiftUI wrapper for WKWebView playing HLS via hls.js
struct HLSWebPlayerView: NSViewRepresentable {
    let url: URL?
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval

    var onCoordinatorReady: ((Coordinator) -> Void)?
    var onPlaybackStarted: (() -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        debugLog("makeNSView called")
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Make sure WebView draws its content
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.black.cgColor

        // Load the HLS player HTML
        debugLog("Loading HTML into WebView")
        webView.loadHTMLString(context.coordinator.playerHTML, baseURL: nil)

        onCoordinatorReady?(context.coordinator)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Load URL if changed and available
        if let url = url, context.coordinator.currentURL != url {
            debugLog("URL available: \(url.absoluteString)")
            context.coordinator.pollAndLoad(url: url)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPlaying: $isPlaying,
            currentTime: $currentTime,
            duration: $duration
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var currentURL: URL?
        private var isReady = false
        private var pendingURL: URL?
        private var hasStartedPlaying = false
        nonisolated(unsafe) private var positionTimer: Timer?

        nonisolated(unsafe) private var isPlayingBinding: Binding<Bool>
        nonisolated(unsafe) private var currentTimeBinding: Binding<TimeInterval>
        nonisolated(unsafe) private var durationBinding: Binding<TimeInterval>
        var onPlaybackStarted: (() -> Void)?

        let playerHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
                video { width: 100%; height: 100%; object-fit: contain; background: #000; }
                #error { color: red; position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); }
            </style>
        </head>
        <body>
            <video id="video" playsinline autoplay></video>
            <div id="error"></div>
            <script>
                const video = document.getElementById('video');
                const errorDiv = document.getElementById('error');

                function log(msg) {
                    window.webkit.messageHandlers.player.postMessage('log:' + msg);
                }

                video.addEventListener('error', function(e) {
                    const err = video.error ? (video.error.code + ': ' + video.error.message) : 'unknown';
                    errorDiv.textContent = err;
                    log('error: ' + err);
                });

                video.addEventListener('loadeddata', function() { log('loadeddata'); });
                video.addEventListener('canplaythrough', function() {
                    log('canplaythrough');
                    video.play();
                });
                video.addEventListener('playing', function() { log('playing'); });
                video.addEventListener('pause', function() { log('paused'); });
                video.addEventListener('play', function() { log('play event'); });
                video.addEventListener('waiting', function() { log('waiting/buffering'); });
                video.addEventListener('stalled', function() { log('stalled'); });
                video.addEventListener('ended', function() { log('ended'); });

                function loadStream(url) {
                    log('load: ' + url);
                    video.src = url;
                    video.load();
                }

                function play() { video.play(); }
                function pause() { video.pause(); }
                function seek(time) { video.currentTime = time; }
                function getState() {
                    return JSON.stringify({
                        currentTime: video.currentTime || 0,
                        duration: video.duration || 0,
                        paused: video.paused
                    });
                }

                window.webkit.messageHandlers.player.postMessage('ready');
            </script>
        </body>
        </html>
        """

        init(isPlaying: Binding<Bool>, currentTime: Binding<TimeInterval>, duration: Binding<TimeInterval>) {
            self.isPlayingBinding = isPlaying
            self.currentTimeBinding = currentTime
            self.durationBinding = duration
            super.init()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            debugLog("webView didFinish navigation")
            // Add message handler for player communication
            webView.configuration.userContentController.add(self, name: "player")
            isReady = true

            // Load pending URL if any
            if let url = pendingURL {
                debugLog("Loading pending URL: \(url)")
                loadInWebView(url: url)
                pendingURL = nil
            } else {
                debugLog("No pending URL")
            }

            // Start position polling
            startPositionTimer()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                if body == "ready" {
                    debugLog("WebView player ready")
                } else if body.hasPrefix("log:") {
                    let msg = String(body.dropFirst(4))
                    debugLog("WebView JS: \(msg)")
                    // Notify when playback starts
                    if msg == "playing" && !hasStartedPlaying {
                        hasStartedPlaying = true
                        onPlaybackStarted?()
                    }
                }
            }
        }

        /// Poll for stream ready and load. Skips if same URL already loaded.
        func pollAndLoad(url: URL) {
            // Use base URL (without query params) for comparison to avoid duplicate loads
            let baseURL = URL(string: url.absoluteString.split(separator: "?").first.map(String.init) ?? url.absoluteString)
            guard currentURL != baseURL else { return }
            forcePollAndLoad(url: url)
        }

        /// Force poll and load, even if same base URL. Used for seeks.
        func forcePollAndLoad(url: URL) {
            // Store base URL to prevent SwiftUI re-triggering
            currentURL = URL(string: url.absoluteString.split(separator: "?").first.map(String.init) ?? url.absoluteString)
            debugLog("pollAndLoad: \(url.absoluteString)")

            // Poll until we have enough buffered content (6+ seconds = 3+ segments at 2s each)
            Task {
                var attempts = 0
                while attempts < 60 {  // 30 seconds max
                    do {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 2
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode == 200,
                           let playlist = String(data: data, encoding: .utf8) {
                            // Parse total duration from EXTINF tags
                            let extinfPattern = try? NSRegularExpression(pattern: "#EXTINF:([\\d.]+),")
                            let matches = extinfPattern?.matches(in: playlist, range: NSRange(playlist.startIndex..., in: playlist)) ?? []
                            var totalDuration: Double = 0
                            for match in matches {
                                if let range = Range(match.range(at: 1), in: playlist),
                                   let duration = Double(playlist[range]) {
                                    totalDuration += duration
                                }
                            }
                            if totalDuration >= 6.0 {
                                debugLog("Stream ready with \(String(format: "%.1f", totalDuration))s buffered")
                                await MainActor.run {
                                    if self.isReady {
                                        self.loadInWebView(url: url)
                                    } else {
                                        self.pendingURL = url
                                    }
                                }
                                return
                            } else {
                                debugLog("Stream has \(String(format: "%.1f", totalDuration))s, waiting for 6s...")
                            }
                        }
                    } catch {
                        // Not ready yet
                    }
                    attempts += 1
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                debugLog("Stream poll timeout")
            }
        }

        func load(url: URL) {
            currentURL = url
            if isReady {
                loadInWebView(url: url)
            } else {
                pendingURL = url
            }
        }

        private func loadInWebView(url: URL) {
            // Reset playback start flag so onPlaybackStarted fires for each new stream load.
            hasStartedPlaying = false
            let js = "loadStream('\(url.absoluteString)');"
            debugLog("loadStream JS: \(url.absoluteString)")
            webView?.evaluateJavaScript(js) { _, error in
                if let error = error {
                    debugLog("JS error: \(error.localizedDescription)")
                }
            }
        }

        private func startPositionTimer() {
            positionTimer?.invalidate()
            positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updatePosition()
            }
        }

        private func updatePosition() {
            webView?.evaluateJavaScript("getState()") { [weak self] result, error in
                guard let self = self,
                      let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                if let time = state["currentTime"] as? Double {
                    self.currentTimeBinding.wrappedValue = time
                }
                if let dur = state["duration"] as? Double, dur.isFinite && dur > 0 {
                    self.durationBinding.wrappedValue = dur
                }
                if let paused = state["paused"] as? Bool {
                    self.isPlayingBinding.wrappedValue = !paused
                }
            }
        }

        func play() {
            webView?.evaluateJavaScript("play()", completionHandler: nil)
        }

        func pause() {
            webView?.evaluateJavaScript("pause()", completionHandler: nil)
        }

        func togglePause() {
            debugLog("togglePause called")
            webView?.evaluateJavaScript("video.paused ? play() : pause()") { result, error in
                if let error = error {
                    debugLog("togglePause error: \(error)")
                } else {
                    debugLog("togglePause success")
                }
            }
        }

        func seek(to time: TimeInterval) {
            webView?.evaluateJavaScript("seek(\(time))", completionHandler: nil)
        }

        deinit {
            positionTimer?.invalidate()
        }
    }
}
