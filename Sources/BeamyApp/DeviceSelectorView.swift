import SwiftUI
import BeamyKit

struct DeviceSelectorView: View {
    @EnvironmentObject var viewModel: CastingViewModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch viewModel.outputType {
        case .chromecast: return "Select Chromecast"
        case .airplay: return "Select AirPlay Device"
        case .mpv: return "Select Device"
        }
    }

    private var relevantDevices: [Any] {
        switch viewModel.outputType {
        case .chromecast: return viewModel.devices
        case .airplay: return viewModel.airPlayDevices
        case .mpv: return []
        }
    }

    private var emptyMessage: String {
        switch viewModel.outputType {
        case .chromecast: return "No Chromecast devices found"
        case .airplay: return "No AirPlay devices found"
        case .mpv: return "No devices"
        }
    }

    private var emptyHint: String {
        switch viewModel.outputType {
        case .chromecast: return "Make sure your Chromecast is on and connected to the same network."
        case .airplay: return "Make sure your Apple TV or AirPlay-enabled TV is on and connected to the same network."
        case .mpv: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(title)
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
            if viewModel.isDiscovering && relevantDevices.isEmpty {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning for devices...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if relevantDevices.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(emptyMessage)
                        .font(.headline)
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Device list - filtered by output type
                List {
                    if viewModel.outputType == .chromecast {
                        ForEach(viewModel.devices, id: \.id) { device in
                            ChromecastDeviceRow(
                                device: device,
                                isSelected: device.id == viewModel.selectedDevice?.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedDevice = device
                                dismiss()
                            }
                        }
                    } else if viewModel.outputType == .airplay {
                        ForEach(viewModel.airPlayDevices, id: \.deviceId) { device in
                            AirPlayDeviceRow(
                                device: device,
                                isSelected: device.deviceId == viewModel.selectedAirPlayDevice?.deviceId
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedAirPlayDevice = device
                                if device.requiresPairing {
                                    viewModel.errorMessage = "Pairing required - not yet implemented"
                                }
                                dismiss()
                            }
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
                    let count = relevantDevices.count
                    Text("\(count) device\(count == 1 ? "" : "s") found")
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
        .frame(width: 350, height: 350)
        .onAppear {
            // Auto-discover if no devices yet
            if relevantDevices.isEmpty {
                viewModel.discoverDevices()
            }
        }
    }
}

// MARK: - Chromecast Device Row

private struct ChromecastDeviceRow: View {
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

// MARK: - AirPlay Device Row

private struct AirPlayDeviceRow: View {
    let device: AirPlayDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "airplayvideo")
                .font(.title2)
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.body)
                        .foregroundColor(.primary)

                    if device.requiresPairing {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Text(device.deviceType)
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
    DeviceSelectorView()
        .environmentObject(CastingViewModel())
}
