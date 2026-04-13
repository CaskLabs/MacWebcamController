import SwiftUI

struct ControlSliderView: View {
    let control: UVCControl
    let state: ControlState
    var onValueChanged: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(control.displayName)
                    .font(.subheadline)
                Spacer()
                Text("\(state.currentValue)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(state.currentValue) },
                    set: { onValueChanged(Int($0.rounded())) }
                ),
                in: Double(state.minimum)...Double(max(state.minimum + 1, state.maximum)),
                step: Double(max(1, state.resolution))
            )
            .disabled(!state.isSupported)
        }
        .opacity(state.isSupported ? 1.0 : 0.5)
    }
}
