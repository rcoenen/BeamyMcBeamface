import SwiftUI
import BeamyKit

struct SettingsView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @State private var ffmpegPath: String = ""
    @State private var ffprobePath: String = ""
    @State private var defaultDevice: String = ""
    @State private var preset: String = "ultrafast"
    @State private var crf: Int = 23
    @State private var audioBitrate: String = "192k"

    var body: some View {
        TabView {
            // FFmpeg settings
            Form {
                Section("FFmpeg Paths") {
                    HStack {
                        TextField("ffmpeg path", text: $ffmpegPath)
                        Button("Browse...") {
                            browseForFile { url in
                                ffmpegPath = url.path
                            }
                        }
                    }
                    HStack {
                        TextField("ffprobe path", text: $ffprobePath)
                        Button("Browse...") {
                            browseForFile { url in
                                ffprobePath = url.path
                            }
                        }
                    }
                }

                Section("Encoding") {
                    Picker("Preset", selection: $preset) {
                        Text("ultrafast").tag("ultrafast")
                        Text("superfast").tag("superfast")
                        Text("veryfast").tag("veryfast")
                        Text("faster").tag("faster")
                        Text("fast").tag("fast")
                        Text("medium").tag("medium")
                    }

                    Stepper("CRF: \(crf)", value: $crf, in: 18...28)

                    Picker("Audio Bitrate", selection: $audioBitrate) {
                        Text("128k").tag("128k")
                        Text("192k").tag("192k")
                        Text("256k").tag("256k")
                        Text("320k").tag("320k")
                    }
                }
            }
            .tabItem {
                Label("FFmpeg", systemImage: "film")
            }

            // Chromecast settings
            Form {
                Section("Default Device") {
                    Picker("Device", selection: $defaultDevice) {
                        Text("None").tag("")
                        ForEach(viewModel.devices, id: \.id) { device in
                            Text(device.name).tag(device.name)
                        }
                    }

                    Button("Refresh Device List") {
                        viewModel.discoverDevices()
                    }
                }
            }
            .tabItem {
                Label("Chromecast", systemImage: "tv")
            }
        }
        .padding()
        .frame(width: 450, height: 300)
        .onAppear {
            loadConfig()
        }
        .onChange(of: ffmpegPath) { _ in saveConfig() }
        .onChange(of: ffprobePath) { _ in saveConfig() }
        .onChange(of: defaultDevice) { _ in saveConfig() }
        .onChange(of: preset) { _ in saveConfig() }
        .onChange(of: crf) { _ in saveConfig() }
        .onChange(of: audioBitrate) { _ in saveConfig() }
    }

    private func loadConfig() {
        guard let config = try? Config.load() else { return }
        ffmpegPath = config.ffmpeg.ffmpegPath
        ffprobePath = config.ffmpeg.ffprobePath
        preset = config.ffmpeg.preset
        crf = config.ffmpeg.crf
        audioBitrate = config.ffmpeg.audioBitrate
        defaultDevice = config.chromecast.defaultDevice ?? ""
    }

    private func saveConfig() {
        guard var config = try? Config.load() else { return }
        config.ffmpeg.ffmpegPath = ffmpegPath
        config.ffmpeg.ffprobePath = ffprobePath
        config.ffmpeg.preset = preset
        config.ffmpeg.crf = crf
        config.ffmpeg.audioBitrate = audioBitrate
        config.chromecast.defaultDevice = defaultDevice.isEmpty ? nil : defaultDevice
        try? config.save()
    }

    private func browseForFile(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(CastingViewModel())
}
