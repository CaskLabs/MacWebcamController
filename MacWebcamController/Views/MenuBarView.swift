import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    // Controls shown in the compact popover
    private let quickControls: [UVCControl] = [
        .brightness, .contrast, .whiteBalanceTemperature, .exposureAbsolute, .focusAbsolute
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CameraPickerView()
                Spacer()
                if viewModel.selectedCamera != nil {
                    CompactButton(help: "Reset all controls to defaults") {
                        viewModel.resetToDefaults()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }

            if viewModel.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading controls…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if viewModel.selectedCamera != nil {
                Divider()

                ForEach(quickControls) { control in
                    if let state = viewModel.controls[control], state.isSupported {
                        ControlSliderView(
                            control: control,
                            state: state,
                            onValueChanged: { value in viewModel.setValue(value, for: control) },
                            isSliderDisabled: isAutoEnabled(for: control)
                        ) {
                            autoToggle(for: control)
                        }
                    }
                }
            } else {
                Text("Select a camera above to adjust settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            HStack(spacing: 6) {
                CompactButton(help: "Open full controls window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Open Full Controls")
                }

                Spacer()

                CompactButton(help: "Settings", horizontalPadding: 16) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gear")
                }

                CompactButton(help: "Quit") {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func isAutoEnabled(for control: UVCControl) -> Bool {
        switch control {
        case .exposureAbsolute:       return viewModel.autoExposureEnabled
        case .whiteBalanceTemperature: return viewModel.whiteBalanceAutoEnabled
        case .focusAbsolute:          return viewModel.focusAutoEnabled
        default:                      return false
        }
    }

    @ViewBuilder
    private func autoToggle(for control: UVCControl) -> some View {
        switch control {
        case .exposureAbsolute where viewModel.autoExposureSupported:
            Toggle("Auto", isOn: Binding(
                get: { viewModel.autoExposureEnabled },
                set: { viewModel.setAutoExposure($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        case .whiteBalanceTemperature where viewModel.whiteBalanceAutoSupported:
            Toggle("Auto", isOn: Binding(
                get: { viewModel.whiteBalanceAutoEnabled },
                set: { viewModel.setWhiteBalanceAuto($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        case .focusAbsolute where viewModel.focusAutoSupported:
            Toggle("Auto", isOn: Binding(
                get: { viewModel.focusAutoEnabled },
                set: { viewModel.setFocusAuto($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        default:
            EmptyView()
        }
    }
}

/// A small borderless button with a rounded-rectangle background box.
private struct CompactButton<Label: View>: View {
    let help: String
    var horizontalPadding: CGFloat = 9
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.body)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }
}
