import SwiftUI

struct MainWindowView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if viewModel.showingSettings {
                    Text("Settings")
                        .font(.headline)
                } else {
                    CameraPickerView()
                    if viewModel.hasSupportedControls {
                        Button("Reset All") {
                            viewModel.resetToDefaults()
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
                Spacer()
                Button {
                    withAnimation { viewModel.showingSettings.toggle() }
                } label: {
                    Image(systemName: viewModel.showingSettings ? "camera" : "gear")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding()
            .background(.bar)

            Divider()

            if viewModel.showingSettings {
                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isLoading {
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
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                        ControlSection(title: "Image", controls: [
                            .brightness, .contrast, .saturation, .sharpness, .gamma
                        ])
                        ExposureSection()
                        FocusSection()
                        WhiteBalanceSection()
                        AntiFlickerSection()
                        PresetsSection()
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

// MARK: - Collapsible Section

private struct CollapsibleSection<Trailing: View, Content: View>: View {
    let title: String
    @State private var isExpanded: Bool = true
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    trailing
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(.top, 10)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension CollapsibleSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Control Section

private struct ControlSection: View {
    let title: String
    let controls: [UVCControl]

    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        let visible = controls.filter { viewModel.controls[$0] != nil }
        if !visible.isEmpty {
            CollapsibleSection(title: title) {
                ForEach(controls) { control in
                    if let state = viewModel.controls[control] {
                        ControlSliderView(control: control, state: state) { value in
                            viewModel.setValue(value, for: control)
                        }
                    }
                }
            }
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
            CollapsibleSection(title: "Exposure & Gain") {
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
                    .disabled(viewModel.autoExposureEnabled)
                    .opacity(viewModel.autoExposureEnabled ? 0.4 : 1.0)
                }

                if hasBacklight, let state = viewModel.controls[.backlightCompensation] {
                    ControlSliderView(control: .backlightCompensation, state: state) { value in
                        viewModel.setValue(value, for: .backlightCompensation)
                    }
                    .disabled(viewModel.autoExposureEnabled)
                    .opacity(viewModel.autoExposureEnabled ? 0.4 : 1.0)
                }
            }
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
            CollapsibleSection(title: "White Balance") {
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
        }
    }
}

// MARK: - Focus Section (with Auto toggle)

private struct FocusSection: View {
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        let hasFocus = viewModel.controls[.focusAbsolute]?.isSupported == true
        let hasAuto = viewModel.focusAutoSupported

        if hasFocus || hasAuto {
            CollapsibleSection(title: "Focus") {
                if hasAuto {
                    Toggle("Auto Focus", isOn: Binding(
                        get: { viewModel.focusAutoEnabled },
                        set: { viewModel.setFocusAuto($0) }
                    ))
                }

                if hasFocus, let state = viewModel.controls[.focusAbsolute] {
                    ControlSliderView(control: .focusAbsolute, state: state) { value in
                        viewModel.setValue(value, for: .focusAbsolute)
                    }
                    .disabled(viewModel.focusAutoEnabled)
                    .opacity(viewModel.focusAutoEnabled ? 0.4 : 1.0)
                }
            }
        }
    }
}

// MARK: - Anti-Flicker (Powerline Frequency) Section

private struct AntiFlickerSection: View {
    @Environment(CameraViewModel.self) private var viewModel

    private let options: [(label: String, value: Int)] = [
        ("Disabled", 0), ("50 Hz", 1), ("60 Hz", 2)
    ]

    var body: some View {
        if let state = viewModel.controls[.powerlineFrequency], state.isSupported {
            CollapsibleSection(title: "Anti-Flicker") {
                HStack(spacing: 6) {
                    ForEach(options, id: \.value) { option in
                        Button(option.label) {
                            viewModel.setValue(option.value, for: .powerlineFrequency)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(state.currentValue == option.value ? Color.white : Color.primary)
                        .background(
                            state.currentValue == option.value ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Presets Section

private struct PresetsSection: View {
    @Environment(CameraViewModel.self) private var viewModel
    @State private var newPresetName: String = ""
    @State private var showingNameField: Bool = false

    var body: some View {
        CollapsibleSection(
            title: "Presets",
            trailing: {
                Button {
                    showingNameField.toggle()
                    newPresetName = ""
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            },
            content: {
                if showingNameField {
                    HStack {
                        TextField("Preset name", text: $newPresetName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { savePreset() }

                        Button("Save") { savePreset() }
                            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Cancel") {
                            showingNameField = false
                            newPresetName = ""
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }

                if viewModel.presets.isEmpty && !showingNameField {
                    Text("No saved presets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    PresetList(
                        presets: viewModel.presets,
                        onApply: { viewModel.applyPreset($0) },
                        onUpdate: { viewModel.updatePreset($0) },
                        onDelete: { viewModel.deletePreset($0) }
                    )
                }
            }
        )
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        viewModel.savePreset(name: name)
        showingNameField = false
        newPresetName = ""
    }
}

// MARK: - Preset Row

private struct PresetRow: View {
    let name: String
    let onApply: () -> Void
    let onUpdate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text(name)
                .lineLimit(1)
            Spacer()
            Button("Apply", action: onApply)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            Button("Update", action: onUpdate)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Button("Delete", action: onDelete)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preset List

private struct PresetList: View {
    let presets: [CameraPreset]
    let onApply: (CameraPreset) -> Void
    let onUpdate: (CameraPreset) -> Void
    let onDelete: (CameraPreset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(presets, id: \CameraPreset.id) { preset in
                PresetRow(
                    name: preset.name,
                    onApply: { onApply(preset) },
                    onUpdate: { onUpdate(preset) },
                    onDelete: { onDelete(preset) }
                )
            }
        }
    }
}
