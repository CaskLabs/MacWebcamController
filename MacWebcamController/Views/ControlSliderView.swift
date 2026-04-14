import SwiftUI
import Combine

struct ControlSliderView: View {
    let control: UVCControl
    let state: ControlState
    var onValueChanged: (Int) -> Void

    // Debounced publisher so rapid slider drags don't flood the USB bus
    @State private var debounceTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(control.displayName)
                    .font(.subheadline)
                Spacer()
                Text("\(state.currentValue)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }

            if state.isSupported && state.maximum > state.minimum {
                Slider(
                    value: Binding(
                        get: { Double(state.currentValue) },
                        // Always move at step 1 for smooth dragging; snap to
                        // the camera's resolution step before sending.
                        set: { newVal in
                            let res = max(1, state.resolution)
                            let snapped = (Int(newVal.rounded()) / res) * res
                            let clamped = max(state.minimum, min(state.maximum, snapped))
                            scheduleUpdate(clamped)
                        }
                    ),
                    in: Double(state.minimum)...Double(state.maximum),
                    step: 1.0
                )
            } else {
                Slider(value: .constant(0))
                    .disabled(true)
            }

            if let error = state.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .opacity(state.isSupported ? 1.0 : 0.4)
    }

    private func scheduleUpdate(_ value: Int) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            onValueChanged(value)
        }
    }
}
