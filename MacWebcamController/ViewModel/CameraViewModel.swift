import Foundation
import Observation

/// Bridges UVC camera state to SwiftUI.
@Observable
@MainActor
final class CameraViewModel {
    var selectedCamera: CameraInfo?
    var selectedCameraID: String?
    var controls: [UVCControl: ControlState] = [:]
    var errorMessage: String?

    init() {
        // Initialize all controls with default (unsupported) state
        for control in UVCControl.allCases {
            controls[control] = ControlState()
        }
    }

    func selectCamera(_ camera: CameraInfo?) {
        selectedCamera = camera
        selectedCameraID = camera?.id

        // Reset controls when camera changes
        for control in UVCControl.allCases {
            controls[control] = ControlState()
        }

        // TODO: Phase 2+ — open UVC device and read actual control values
    }

    func setValue(_ value: Int, for control: UVCControl) {
        controls[control]?.currentValue = value
        // TODO: Phase 2+ — send SET_CUR to device
    }

    func resetToDefaults() {
        for control in UVCControl.allCases {
            if let state = controls[control], state.isSupported {
                setValue(state.defaultValue, for: control)
            }
        }
    }
}
