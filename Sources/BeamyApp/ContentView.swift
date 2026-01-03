import SwiftUI
import BeamyKit
import UniformTypeIdentifiers

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

            // Drop zone
            ZStack {
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
                    if let currentFile = viewModel.currentFile {
                        Image(systemName: "film")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(currentFile.lastPathComponent)
                            .font(.headline)
                        if viewModel.isCasting {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Casting to \(viewModel.selectedDevice?.name ?? "device")...")
                            }
                            .foregroundColor(.secondary)
                        }
                    } else {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Drop videos here to start casting...")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

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
        .frame(minWidth: 400, minHeight: 300)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

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
