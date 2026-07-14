import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showPreviewInMenuBar") private var showPreviewInMenuBar = false
    @State private var isMenuPreviewActive = false
    // Controls shown in the compact popover
    private let quickControls: [UVCControl] = [
        .brightness, .contrast, .whiteBalanceTemperature, .exposureAbsolute, .focusAbsolute
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CameraPickerView()
                Spacer()
                if viewModel.hasSupportedControls {
                    CompactButton(help: "Reset all controls to defaults") {
                        viewModel.resetToDefaults()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }

            if showPreviewInMenuBar, let cameraID = viewModel.selectedCamera?.id {
                if isMenuPreviewActive {
                    ZStack(alignment: .topTrailing) {
                        CameraPreviewView(
                            cameraID: cameraID,
                            releaseImmediatelyWhenRemoved: true
                        )
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 176)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            isMenuPreviewActive = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                    }
                } else {
                    Button {
                        isMenuPreviewActive = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "video")
                                .font(.title2)
                            Text("Show Preview")
                                .font(.body)
                            Text("The camera remains available to other apps until requested.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 146)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
                if hasSupportedQuickControls {
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

            if hasSupportedQuickControls {
                Divider()
            }

            HStack(spacing: 6) {
                CompactButton(help: "Open full controls window") {
                    viewModel.showingSettings = false
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Open Full Controls")
                }

                Spacer()

                CompactButton(help: "Settings", horizontalPadding: 16) {
                    viewModel.showingSettings = true
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
        .onDisappear {
            isMenuPreviewActive = false
        }
        .onChange(of: showPreviewInMenuBar) { _, enabled in
            if !enabled {
                isMenuPreviewActive = false
            }
        }
    }

    private var hasSupportedQuickControls: Bool {
        quickControls.contains { control in
            viewModel.controls[control]?.isSupported == true
        }
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
