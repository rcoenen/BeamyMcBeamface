import SwiftUI
import BeamyKit

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // App info
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("Beamy McBeamface")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            Divider()
                .padding(.horizontal)

            // Technical info
            VStack(alignment: .leading, spacing: 6) {
                Label("Video: Apple VideoToolbox (H.264)", systemImage: "film")
                Label("Audio: Apple AudioToolbox (AAC)", systemImage: "speaker.wave.2")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Spacer()

            // FFmpeg attribution
            VStack(spacing: 4) {
                Text("This software uses FFmpeg under the LGPL v2.1")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Link("ffmpeg.org", destination: URL(string: "https://ffmpeg.org")!)
                    .font(.caption2)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .frame(width: 280, height: 260)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
