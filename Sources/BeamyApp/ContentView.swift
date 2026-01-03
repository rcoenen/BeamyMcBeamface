import SwiftUI
import BeamyKit
import UniformTypeIdentifiers
import AVKit

// MARK: - Drop Zone that actually works
class DropZoneNSView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        print("[NSVIEW] draggingEntered")
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        print("[NSVIEW] performDragOperation")
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first else {
            print("[NSVIEW] No URL found")
            return false
        }
        print("[NSVIEW] Got URL: \(url.path)")
        onDrop?(url)
        return true
    }
}

struct DropZoneView: NSViewRepresentable {
    let onDrop: (URL) -> Void

    func makeNSView(context: Context) -> DropZoneNSView {
        let view = DropZoneNSView()
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropZoneNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}


// MARK: - Playback Controls

struct PlaybackControlsView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            // Seek bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track background
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 4)

                    // Progress
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * (isDragging ? dragProgress : viewModel.progress), height: 4)

                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .shadow(radius: 2)
                        .offset(x: geometry.size.width * (isDragging ? dragProgress : viewModel.progress) - 6)
                }
                .frame(height: 12)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragProgress = min(max(value.location.x / geometry.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let progress = min(max(value.location.x / geometry.size.width, 0), 1)
                            viewModel.seekToProgress(progress)
                            isDragging = false
                        }
                )
            }
            .frame(height: 12)

            // Controls row
            HStack {
                // Current time
                Text(CastingViewModel.formatTime(viewModel.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)

                Spacer()

                // Skip backward 10s
                Button(action: { viewModel.skipBackward() }) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.borderless)

                // Play/Pause
                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)
                .frame(width: 44)

                // Skip forward 10s
                Button(action: { viewModel.skipForward() }) {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(.borderless)

                Spacer()

                // Time remaining
                Text("-\(CastingViewModel.formatTime(viewModel.timeRemaining))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }

            // Duration display
            if let file = viewModel.currentFile {
                Text(file.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Video Preview using AVPlayer
struct VideoPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.videoGravity = .resizeAspect
        view.layer?.addSublayer(playerLayer)

        // Start playing
        player.play()

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Update player layer frame if needed
        if let playerLayer = nsView.layer?.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = nsView.bounds
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @State private var isTargeted = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Device picker
                HStack(spacing: 8) {
                    Text("Chromecast:")
                        .foregroundColor(.white)

                    Picker("", selection: $viewModel.selectedDevice) {
                        Text("Select device...").tag(nil as ChromecastDevice?)
                        ForEach(viewModel.devices, id: \.id) { device in
                            Text(device.name).tag(device as ChromecastDevice?)
                        }
                    }
                    .frame(width: 180)

                    Button(action: { viewModel.discoverDevices() }) {
                        Image(systemName: viewModel.isDiscovering ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.white)
                    .disabled(viewModel.isDiscovering)
                }

                Spacer()

                Button("settings") {
                    showSettings = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .frame(height: 60)
            .background(Color(nsColor: .darkGray))
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(viewModel)
            }

            // Control panel or drop zone - NO animation to avoid AVPlayer crash
            ZStack {
                if viewModel.currentFile != nil {
                    // Transcoder control panel
                    VStack(spacing: 0) {
                        VStack(spacing: 20) {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(spacing: 12) {
                                    // File name
                                    if let file = viewModel.currentFile {
                                        Text(file.lastPathComponent)
                                            .font(.title2)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    // Current time - large display
                                    Text(CastingViewModel.formatTime(viewModel.currentTime))
                                        .font(.system(size: 64, weight: .medium, design: .monospaced))
                                        .foregroundColor(.primary)

                                    Text("of \(CastingViewModel.formatTime(viewModel.duration))")
                                        .font(.title3)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                // Video preview
                                if let server = viewModel.transcodeServer {
                                    VideoPreviewView(url: server.url)
                                        .frame(width: 360, height: 203)
                                        .cornerRadius(8)
                                        .clipped()
                                } else {
                                    Rectangle()
                                        .fill(Color.black)
                                        .frame(width: 360, height: 203)
                                        .cornerRadius(8)
                                        .overlay(
                                            Text("Starting...")
                                                .foregroundColor(.gray)
                                        )
                                }
                            }

                            // Stream URL for VLC/external players
                            if let server = viewModel.transcodeServer {
                                VStack(spacing: 8) {
                                    Text("Stream URL:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(server.url.absoluteString)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(4)

                                    Button("Open in VLC") {
                                        let process = Process()
                                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                                        process.arguments = ["-a", "VLC", server.url.absoluteString]
                                        try? process.run()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.top, 10)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Playback controls
                        PlaybackControlsView()
                            .environmentObject(viewModel)
                    }
                } else {
                    // Drop zone
                    Rectangle()
                        .fill(Color(nsColor: .lightGray).opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isTargeted ? Color.blue : Color.clear,
                                    style: StrokeStyle(lineWidth: 3, dash: [10])
                                )
                                .padding(20)
                        )

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Drop videos here to preview...")
                            .font(.title2)
                            .foregroundColor(.primary)

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .animation(nil, value: viewModel.currentFile != nil)  // Disable animation to prevent AVPlayer crash
            // Supported formats bar
            HStack(spacing: 6) {
                Text("Supported formats:")
                    .foregroundColor(.secondary)
                ForEach(["MP4", "MKV", "WEBM", "MOV"], id: \.self) { format in
                    Text(format)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            print("[CONTENT] onDrop triggered!")
            return handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("[CONTENT] handleDrop called with \(providers.count) providers")
        guard let provider = providers.first else {
            print("[CONTENT] No provider!")
            return false
        }

        print("[CONTENT] Loading item...")
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            print("[CONTENT] loadItem callback - item: \(String(describing: item)), error: \(String(describing: error))")
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                print("[CONTENT] Failed to get URL from data")
                return
            }

            print("[CONTENT] Got URL: \(url.path)")
            DispatchQueue.main.async {
                viewModel.handleFileDrop(url: url)
            }
        }

        return true
    }
}

#Preview {
    ContentView()
        .environmentObject(CastingViewModel())
}
