import SwiftUI
import BeamyKit
import UniformTypeIdentifiers

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
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first else {
            return false
        }
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

                    // Time overlay while dragging
                    if isDragging {
                        let targetTime = dragProgress * viewModel.effectiveDuration
                        Text(CastingViewModel.formatTime(targetTime))
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                            .shadow(radius: 3)
                            .offset(x: min(max(geometry.size.width * dragProgress - 35, 0), geometry.size.width - 70), y: -30)
                    }
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

                Spacer()
                    .frame(width: 32)

                // Play/Pause
                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)
                .frame(width: 44)

                // Stop button
                Button(action: { viewModel.stopAndReset() }) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop playback")

                Spacer()
                    .frame(width: 32)

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

            // Status message
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}


// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @State private var isTargeted = false
    @State private var showSettings = false
    @State private var showDeviceSelector = false

    private var outputIcon: String {
        switch viewModel.outputType {
        case .mpv: return "desktopcomputer"
        case .chromecast: return "tv"
        case .airplay: return "airplayvideo"
        }
    }

    private var outputDescription: String {
        switch viewModel.outputType {
        case .mpv:
            return "Playing locally via mpv"
        case .chromecast:
            if let device = viewModel.selectedDevice {
                return "Casting to \(device.name)"
            }
            return "Chromecast - no device selected"
        case .airplay:
            if let device = viewModel.selectedAirPlayDevice {
                return "AirPlay to \(device.name)"
            }
            return "AirPlay - no device selected"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 0) {
                // Left: Beamy logo
                Image("BeamyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 90)
                    .fixedSize()

                Spacer()

                // Center: Output controls (stacked vertically)
                VStack(spacing: 8) {
                    Text("Output")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    // Beamy/Chromecast/AirPlay picker
                    Picker("", selection: Binding(
                        get: { viewModel.outputType },
                        set: { newValue in
                            viewModel.switchOutput(to: newValue)
                        }
                    )) {
                        Text("Beamy").tag(OutputType.mpv)
                        Text("Chromecast").tag(OutputType.chromecast)
                        Text("AirPlay").tag(OutputType.airplay)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .disabled(viewModel.isSwitchingOutput)

                    // Device selector (or switching indicator)
                    if viewModel.isSwitchingOutput {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Switching...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if viewModel.outputType == .chromecast {
                        Button(action: { showDeviceSelector = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "tv")
                                Text(viewModel.selectedDevice?.name ?? "Select Chromecast...")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(width: 200)
                    } else if viewModel.outputType == .airplay {
                        Button(action: { showDeviceSelector = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "airplayvideo")
                                if let device = viewModel.selectedAirPlayDevice {
                                    if device.requiresPairing {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                    }
                                    Text(device.name)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                } else {
                                    Text("Select AirPlay...")
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(width: 200)
                    }
                }

                Spacer()

                // Right: Beamy icon
                Image("BeamyIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 140)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $showDeviceSelector) {
                DeviceSelectorView()
                    .environmentObject(viewModel)
            }

            // Control panel or drop zone
            ZStack {
                if viewModel.currentFile != nil {
                    // Playback panel
                    VStack(spacing: 0) {
                        // Main content area - embedded player or info display
                        if viewModel.useEmbeddedPlayer && viewModel.outputType == .mpv {
                            // Embedded WebView with HLS consuming transcoded stream
                            if viewModel.isStreamReady {
                                HLSWebPlayerView(
                                    url: viewModel.transcodeServer?.url,
                                    isPlaying: $viewModel.embeddedIsPlaying,
                                    currentTime: $viewModel.embeddedCurrentTime,
                                    duration: $viewModel.embeddedDuration,
                                    onCoordinatorReady: { coordinator in
                                        viewModel.hlsWebPlayerCoordinator = coordinator
                                        coordinator.onPlaybackStarted = {
                                            viewModel.embeddedPlaybackStarted()
                                        }
                                        // Start transcoder now that WebView is ready
                                        viewModel.startTranscoderForEmbedded()
                                    }
                                )
                                .background(Color.black)
                            } else {
                                // Show loading state while getting media info
                                Color.black
                                    .overlay(
                                        VStack(spacing: 12) {
                                            ProgressView()
                                                .scaleEffect(1.5)
                                            Text(viewModel.statusMessage)
                                                .foregroundColor(.white)
                                        }
                                    )
                            }
                        } else {
                            // Non-embedded mode: file info and status
                            VStack(spacing: 16) {
                                Spacer()

                                // File name
                                if let file = viewModel.currentFile {
                                    HStack(spacing: 8) {
                                        Image(systemName: "film")
                                            .font(.title2)
                                        Text(file.lastPathComponent)
                                            .font(.title2)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .foregroundColor(.primary)
                                }

                                // Output indicator
                                HStack(spacing: 8) {
                                    Image(systemName: outputIcon)
                                    Text(outputDescription)
                                }
                                .font(.headline)
                                .foregroundColor(.secondary)

                                // Error message
                                if let error = viewModel.errorMessage {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                        .padding(.horizontal)
                                }

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        // Playback controls
                        PlaybackControlsView()
                            .environmentObject(viewModel)
                    }
                } else {
                    // Drop zone
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isTargeted ? Color.blue : Color.gray.opacity(0.3),
                                    style: StrokeStyle(lineWidth: 3, dash: [10])
                                )
                                .padding(8)
                        )

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Drop a video file to start")
                            .font(.title2)
                            .foregroundColor(.primary)

                        Text("Supported: MP4, MKV, WEBM, MOV, AVI")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            return handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

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
