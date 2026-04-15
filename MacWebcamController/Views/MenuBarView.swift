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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CameraPickerView()
                if viewModel.selectedCamera != nil {
                    Button {
                        viewModel.resetToDefaults()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reset all controls to defaults")
                }
            }

            if viewModel.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading controls…")
                        .font(.caption)
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
                        .controlSize(.small)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Button("Open Full Controls") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Settings")

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
