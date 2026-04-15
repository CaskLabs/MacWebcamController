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
                    if control == .exposureAbsolute && viewModel.autoExposureSupported && viewModel.controls[control]?.isSupported == true {
                        Toggle("Auto Exposure", isOn: Binding(
                            get: { viewModel.autoExposureEnabled },
                            set: { viewModel.setAutoExposure($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                    }
                    if let state = viewModel.controls[control], state.isSupported {
                        ControlSliderView(control: control, state: state) { value in
                            viewModel.setValue(value, for: control)
                        }
                        .disabled(control == .exposureAbsolute && viewModel.autoExposureEnabled)
                        .opacity(control == .exposureAbsolute && viewModel.autoExposureEnabled ? 0.4 : 1.0)
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

                CompactButton(help: "Settings") {
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
}

/// A small borderless button with a rounded-rectangle background box.
private struct CompactButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.body)
                .padding(.horizontal, 9)
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
