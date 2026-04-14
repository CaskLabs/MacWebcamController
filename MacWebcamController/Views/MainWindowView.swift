import SwiftUI

struct MainWindowView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header: camera picker
            HStack {
                CameraPickerView()
                Spacer()
                if viewModel.selectedCamera != nil {
                    Button("Reset All") {
                        viewModel.resetToDefaults()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding()
            .background(.bar)

            Divider()

            if viewModel.isLoading {
                ProgressView("Loading camera controls…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.selectedCamera != nil {
                // Live preview — fixed 16:9 aspect ratio, max 240pt tall
                CameraPreviewView(cameraID: viewModel.selectedCamera?.id)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxHeight: 240)
                    .background(.black)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                        ControlSection(title: "Image", controls: [
                            .brightness, .contrast, .saturation, .sharpness, .gamma
                        ])
                        ExposureSection()
                        ControlSection(title: "Focus", controls: [.focusAbsolute])
                        WhiteBalanceSection()
                        AntiFlickerSection()
                    }
                    .padding()
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "No Camera Selected",
                    systemImage: "camera",
                    description: Text("Connect a USB UVC camera and select it from the menu above.")
                )
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .navigationTitle("Camera Controls")
    }
}

// MARK: - Control Section

private struct ControlSection: View {
    let title: String
    let controls: [UVCControl]

    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        let supported = controls.filter { viewModel.controls[$0]?.isSupported == true }
        let unsupported = controls.filter { viewModel.controls[$0]?.isSupported == false }

        if !supported.isEmpty || !unsupported.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 2)

                ForEach(controls) { control in
                    if let state = viewModel.controls[control] {
                        ControlSliderView(control: control, state: state) { value in
                            viewModel.setValue(value, for: control)
                        }
                    }
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Exposure Section (with Auto toggle)

private struct ExposureSection: View {
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        let hasExposure = viewModel.controls[.exposureAbsolute]?.isSupported == true
        let hasGain = viewModel.controls[.gain]?.isSupported == true
        let hasBacklight = viewModel.controls[.backlightCompensation]?.isSupported == true
        let hasAuto = viewModel.autoExposureSupported

        if hasExposure || hasGain || hasBacklight || hasAuto {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exposure & Gain")
                    .font(.headline)
                    .padding(.bottom, 2)

                if hasAuto {
                    Toggle("Auto Exposure", isOn: Binding(
                        get: { viewModel.autoExposureEnabled },
                        set: { viewModel.setAutoExposure($0) }
                    ))
                }

                if hasExposure, let state = viewModel.controls[.exposureAbsolute] {
                    ControlSliderView(control: .exposureAbsolute, state: state) { value in
                        viewModel.setValue(value, for: .exposureAbsolute)
                    }
                    .disabled(viewModel.autoExposureEnabled)
                    .opacity(viewModel.autoExposureEnabled ? 0.4 : 1.0)
                }

                if hasGain, let state = viewModel.controls[.gain] {
                    ControlSliderView(control: .gain, state: state) { value in
                        viewModel.setValue(value, for: .gain)
                    }
                }

                if hasBacklight, let state = viewModel.controls[.backlightCompensation] {
                    ControlSliderView(control: .backlightCompensation, state: state) { value in
                        viewModel.setValue(value, for: .backlightCompensation)
                    }
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - White Balance Section (with Auto toggle)

private struct WhiteBalanceSection: View {
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        let hasWB = viewModel.controls[.whiteBalanceTemperature]?.isSupported == true
        let hasAuto = viewModel.whiteBalanceAutoSupported

        if hasWB || hasAuto {
            VStack(alignment: .leading, spacing: 8) {
                Text("White Balance")
                    .font(.headline)
                    .padding(.bottom, 2)

                if hasAuto {
                    Toggle("Auto White Balance", isOn: Binding(
                        get: { viewModel.whiteBalanceAutoEnabled },
                        set: { viewModel.setWhiteBalanceAuto($0) }
                    ))
                }

                if hasWB, let state = viewModel.controls[.whiteBalanceTemperature] {
                    ControlSliderView(control: .whiteBalanceTemperature, state: state) { value in
                        viewModel.setValue(value, for: .whiteBalanceTemperature)
                    }
                    .disabled(viewModel.whiteBalanceAutoEnabled)
                    .opacity(viewModel.whiteBalanceAutoEnabled ? 0.4 : 1.0)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Anti-Flicker (Powerline Frequency) Section

private struct AntiFlickerSection: View {
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        if let state = viewModel.controls[.powerlineFrequency], state.isSupported {
            VStack(alignment: .leading, spacing: 8) {
                Text("Anti-Flicker")
                    .font(.headline)
                    .padding(.bottom, 2)

                Picker("Powerline Frequency", selection: Binding(
                    get: { state.currentValue },
                    set: { viewModel.setValue($0, for: .powerlineFrequency) }
                )) {
                    Text("Disabled").tag(0)
                    Text("50 Hz").tag(1)
                    Text("60 Hz").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
