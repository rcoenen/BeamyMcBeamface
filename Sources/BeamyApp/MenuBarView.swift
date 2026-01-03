import SwiftUI
import BeamyKit

struct MenuBarView: View {
    @EnvironmentObject var viewModel: CastingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Beamy McBeamface")
                .font(.headline)

            Divider()

            // Device picker
            if viewModel.devices.isEmpty {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Discovering devices...")
                        .foregroundColor(.secondary)
                }
            } else {
                Picker("Device", selection: $viewModel.selectedDevice) {
                    Text("Select device...").tag(nil as ChromecastDevice?)
                    ForEach(viewModel.devices, id: \.id) { device in
                        Text(device.name).tag(device as ChromecastDevice?)
                    }
                }
                .pickerStyle(.menu)
            }

            // Current status
            if let file = viewModel.currentFile {
                Divider()
                HStack {
                    Image(systemName: "film")
                    Text(file.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(.secondary)

                if viewModel.isCasting {
                    HStack {
                        Image(systemName: "dot.radiowaves.right")
                        Text("Casting...")
                    }
                    .foregroundColor(.green)
                }
            }

            Divider()

            // Actions
            Button("Refresh Devices") {
                viewModel.discoverDevices()
            }

            Button("Open Main Window") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.isEmpty || $0.title == "Beamy McBeamface" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 250)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(CastingViewModel())
}
