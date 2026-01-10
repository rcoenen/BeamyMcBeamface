import SwiftUI
import BeamyKit

struct SettingsView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @Environment(\.dismiss) var dismiss
    @State private var ffmpegPath: String = ""
    @State private var ffprobePath: String = ""
    @State private var preset: String = "ultrafast"
    @State private var crf: Int = 23
    @State private var audioBitrate: String = "192k"

    // Default values for comparison
    private let defaults = Config.default

    private var hasChangesFromDefaults: Bool {
        ffmpegPath != defaults.ffmpeg.ffmpegPath ||
        ffprobePath != defaults.ffmpeg.ffprobePath ||
        preset != defaults.ffmpeg.preset ||
        crf != defaults.ffmpeg.crf ||
        audioBitrate != defaults.ffmpeg.audioBitrate
    }

    var body: some View {
        Form {
                // FFmpeg status
                Section {
                    HStack {
                        Image(systemName: FFmpeg.isAvailable() ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(FFmpeg.isAvailable() ? .green : .red)
                            .font(.title2)
                        Text(FFmpeg.isAvailable() ? "FFmpeg found" : "FFmpeg not found")
                            .font(.headline)
                    }
                }

                Section("FFmpeg Paths") {
                    HStack {
                        TextField("ffmpeg path", text: $ffmpegPath)
                        Button("Browse...") {
                            browseForFile(currentPath: ffmpegPath) { url in
                                ffmpegPath = url.path
                            }
                        }
                    }
                    HStack {
                        TextField("ffprobe path", text: $ffprobePath)
                        Button("Browse...") {
                            browseForFile(currentPath: ffprobePath) { url in
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

                Section {
                    Button("Restore Defaults") {
                        restoreDefaults()
                    }
                    .disabled(!hasChangesFromDefaults)
                }

                Section("About") {
                    Text("This software uses FFmpeg under the LGPL v2.1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("FFmpeg Project", destination: URL(string: "https://ffmpeg.org")!)
                        .font(.caption)
                    Text("Video encoding: Apple VideoToolbox")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        .padding()
        .frame(width: 450, height: 350)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .onAppear {
            loadConfig()
        }
        .onChange(of: ffmpegPath) { _ in saveConfig() }
        .onChange(of: ffprobePath) { _ in saveConfig() }
        .onChange(of: preset) { _ in saveConfig() }
        .onChange(of: crf) { _ in saveConfig() }
        .onChange(of: audioBitrate) { _ in saveConfig() }
    }

    private func loadConfig() {
        let config = (try? Config.load()) ?? Config.default
        ffmpegPath = config.ffmpeg.ffmpegPath
        ffprobePath = config.ffmpeg.ffprobePath
        preset = config.ffmpeg.preset
        crf = config.ffmpeg.crf
        audioBitrate = config.ffmpeg.audioBitrate
    }

    private func saveConfig() {
        guard var config = try? Config.load() else { return }
        config.ffmpeg.ffmpegPath = ffmpegPath
        config.ffmpeg.ffprobePath = ffprobePath
        config.ffmpeg.preset = preset
        config.ffmpeg.crf = crf
        config.ffmpeg.audioBitrate = audioBitrate
        try? config.save()
    }

    private func restoreDefaults() {
        ffmpegPath = defaults.ffmpeg.ffmpegPath
        ffprobePath = defaults.ffmpeg.ffprobePath
        preset = defaults.ffmpeg.preset
        crf = defaults.ffmpeg.crf
        audioBitrate = defaults.ffmpeg.audioBitrate
    }

    private func browseForFile(currentPath: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Open in directory of current path if it exists
        if !currentPath.isEmpty {
            let currentURL = URL(fileURLWithPath: currentPath)
            let directory = currentURL.deletingLastPathComponent()
            panel.directoryURL = directory
        }

        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(CastingViewModel())
}
