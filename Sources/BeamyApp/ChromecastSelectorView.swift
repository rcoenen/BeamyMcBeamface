import SwiftUI
import BeamyKit

struct ChromecastSelectorView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Chromecast Device")
                    .font(.headline)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Device list or loading/empty state
            if viewModel.isDiscovering && viewModel.devices.isEmpty {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning for Chromecast devices...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.devices.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Chromecast devices found")
                        .font(.headline)
                    Text("Make sure your Chromecast is on and connected to the same network.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Device list
                List {
                    // None option - switches to mpv
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("None (use mpv)")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Switch to local playback")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectedDevice = nil
                        viewModel.switchOutput(to: .mpv)
                        dismiss()
                    }

                    // Chromecast devices
                    ForEach(viewModel.devices, id: \.id) { device in
                        DeviceRow(device: device, isSelected: device.id == viewModel.selectedDevice?.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedDevice = device
                                dismiss()
                            }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer with Rescan button
            HStack {
                // Discovery status
                if viewModel.isDiscovering {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("\(viewModel.devices.count) device\(viewModel.devices.count == 1 ? "" : "s") found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { viewModel.discoverDevices() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Rescan")
                    }
                }
                .disabled(viewModel.isDiscovering)

                Button("Cancel") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(width: 400, height: 350)
        .onAppear {
            // Auto-discover if no devices yet
            if viewModel.devices.isEmpty {
                viewModel.discoverDevices()
            }
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: ChromecastDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.title2)
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .foregroundColor(.primary)

                if let model = device.model {
                    Text(model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }
}

#Preview {
    ChromecastSelectorView()
        .environmentObject(CastingViewModel())
}
