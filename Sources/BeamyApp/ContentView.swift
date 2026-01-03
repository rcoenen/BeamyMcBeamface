import SwiftUI
import BeamyKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Spacer()
                Button("settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.bordered)
                .padding()
            }
            .frame(height: 60)
            .background(Color(nsColor: .darkGray))

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
