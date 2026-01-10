import SwiftUI
import BeamyKit

struct SettingsView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @Environment(\.dismiss) var dismiss
    @State private var audioBitrate: String = "192k"

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("FFmpeg Bundled")
                            .font(.headline)
                        Text("Using hardware-accelerated VideoToolbox encoding")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Audio") {
                Picker("Audio Bitrate", selection: $audioBitrate) {
                    Text("128k").tag("128k")
                    Text("192k").tag("192k")
                    Text("256k").tag("256k")
                    Text("320k").tag("320k")
                }
            }

            Section("About") {
                Text("Beamy McBeamface v0.2")
                    .font(.headline)
                Divider()
                Text("This software uses FFmpeg under the LGPL v2.1")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link("FFmpeg Project", destination: URL(string: "https://ffmpeg.org")!)
                    .font(.caption)
                Text("Video encoding: Apple VideoToolbox (H.264)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Audio encoding: Apple AudioToolbox (AAC)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 400, height: 280)
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
        .onChange(of: audioBitrate) { _ in saveConfig() }
    }

    private func loadConfig() {
        let config = (try? Config.load()) ?? Config.default
        audioBitrate = config.ffmpeg.audioBitrate
    }

    private func saveConfig() {
        guard var config = try? Config.load() else { return }
        config.ffmpeg.audioBitrate = audioBitrate
        try? config.save()
    }
}

#Preview {
    SettingsView()
        .environmentObject(CastingViewModel())
}
