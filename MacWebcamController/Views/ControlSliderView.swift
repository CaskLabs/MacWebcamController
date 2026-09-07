import SwiftUI

struct ControlSliderView<Accessory: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    let control: UVCControl
    let state: ControlState
    var onValueChanged: (Int) -> Void
    var isSliderDisabled: Bool
    var accessory: Accessory

    // Local state tracks the slider position immediately — no waiting for ViewModel round-trip.
    @State private var localValue: Double = 0
    @State private var isDragging = false
    @State private var debounceTask: Task<Void, Never>?

    init(
        control: UVCControl,
        state: ControlState,
        onValueChanged: @escaping (Int) -> Void,
        isSliderDisabled: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.control = control
        self.state = state
        self.onValueChanged = onValueChanged
        self.isSliderDisabled = isSliderDisabled
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(control.displayName)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(localValue.rounded()))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Group {
                    if state.isSupported && state.maximum > state.minimum {
                        Slider(
                            value: $localValue,
                            in: Double(state.minimum)...Double(state.maximum),
                            onEditingChanged: { editing in
                                isDragging = editing
                                if !editing {
                                    // Dragging ended — flush immediately without waiting for debounce
                                    debounceTask?.cancel()
                                    let snapped = snapToValidValue(localValue)
                                    localValue = Double(snapped)
                                    onValueChanged(snapped)
                                }
                            }
                        )
                        .onChange(of: localValue) { _, newVal in
                            guard isDragging else { return }
                            scheduleUpdate(snapToValidValue(newVal))
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    resetToDefault()
                                }
                        )
                        .help("Double-click to reset to the default value")
                    } else {
                        Slider(value: .constant(0))
                            .disabled(true)
                    }
                }
                .disabled(isSliderDisabled)
                .opacity(isSliderDisabled ? 0.4 : 1.0)

                accessory
            }

            if let error = state.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .opacity(state.isSupported ? 1.0 : 0.4)
        .onAppear {
            localValue = Double(state.currentValue)
        }
        .onChange(of: state.currentValue) { _, newValue in
            // Sync from ViewModel only when not dragging (preset applied, initial load, etc.)
            guard !isDragging else { return }
            localValue = Double(newValue)
        }
    }

    /// Snaps a slider value to the device's resolution grid, which starts at
    /// the control's minimum rather than at zero, and keeps it in range.
    private func snapToValidValue(_ value: Double) -> Int {
        let resolution = max(1, state.resolution)
        let offset = value - Double(state.minimum)
        let steps = (offset / Double(resolution)).rounded()
        let snapped = state.minimum + Int(steps) * resolution
        return max(state.minimum, min(state.maximum, snapped))
    }

    private func resetToDefault() {
        guard isEnabled && !isSliderDisabled else { return }

        debounceTask?.cancel()
        let defaultValue = snapToValidValue(Double(state.defaultValue))
        localValue = Double(defaultValue)
        onValueChanged(defaultValue)
    }

    @MainActor
    private func scheduleUpdate(_ value: Int) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            onValueChanged(value)
        }
    }
}

extension ControlSliderView where Accessory == EmptyView {
    init(control: UVCControl, state: ControlState, onValueChanged: @escaping (Int) -> Void) {
        self.init(control: control, state: state, onValueChanged: onValueChanged, isSliderDisabled: false) {
            EmptyView()
        }
    }
}
