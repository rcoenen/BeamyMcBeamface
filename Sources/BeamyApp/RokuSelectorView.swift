import SwiftUI
import BeamyKit

struct RokuSelectorView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Roku Device")
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
            if viewModel.isDiscovering && viewModel.rokuDevices.isEmpty {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning for Roku devices...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rokuDevices.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Roku devices found")
                        .font(.headline)
                    Text("Make sure your Roku is on and connected to the same network.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Device list
                List {
                    // None option - switches to Beamy
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("None (use Beamy)")
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
                        viewModel.selectedRokuDevice = nil
                        viewModel.switchOutput(to: .mpv)
                        dismiss()
                    }

                    // Roku devices
                    ForEach(viewModel.rokuDevices, id: \.id) { device in
                        RokuDeviceRow(device: device, isSelected: device.id == viewModel.selectedRokuDevice?.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedRokuDevice = device
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
                    Text("\(viewModel.rokuDevices.count) Roku\(viewModel.rokuDevices.count == 1 ? "" : "s") found")
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
            if viewModel.rokuDevices.isEmpty {
                viewModel.discoverDevices()
            }
        }
    }
}

// MARK: - Roku Device Row

private struct RokuDeviceRow: View {
    let device: RokuDevice
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

                Text(device.model)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
    RokuSelectorView()
        .environmentObject(CastingViewModel())
}
