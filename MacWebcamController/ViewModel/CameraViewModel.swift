import Foundation
import Observation

/// Bridges UVC camera hardware state to SwiftUI.
/// All IOKit I/O is dispatched on a dedicated serial queue; UI state is updated on the main actor.
@Observable
@MainActor
final class CameraViewModel {
    var selectedCamera: CameraInfo?
    var selectedCameraID: String?
    var controls: [UVCControl: ControlState] = [:]
    var errorMessage: String?
    var isLoading: Bool = false

    // Auto-mode state
    var autoExposureEnabled: Bool = false
    var autoExposureSupported: Bool = false
    var whiteBalanceAutoEnabled: Bool = false
    var whiteBalanceAutoSupported: Bool = false

    private let ioQueue = DispatchQueue(label: "com.macwebcamcontroller.uvc", qos: .userInitiated)

    init() {
        resetControls()
    }

    // MARK: - Camera Selection

    func selectCamera(_ camera: CameraInfo?) {
        selectedCamera = camera
        selectedCameraID = camera?.id
        errorMessage = nil
        resetControls()
        autoExposureEnabled = false
        autoExposureSupported = false
        whiteBalanceAutoEnabled = false
        whiteBalanceAutoSupported = false

        guard let camera, let device = camera.uvcDevice else { return }

        isLoading = true
        ioQueue.async { [weak self] in
            self?.loadControls(from: device, cameraID: camera.id)
        }
    }

    // MARK: - Control Loading

    private func resetControls() {
        controls = Dictionary(uniqueKeysWithValues:
            UVCControl.allCases.map { ($0, ControlState()) }
        )
    }

    /// Reads all control values and ranges from the UVC device (runs on ioQueue).
    private func loadControls(from device: UVCDevice, cameraID: String) {
        var updated: [UVCControl: ControlState] = [:]

        for control in UVCControl.allCases {
            var state = ControlState()
            state.isSupported = device.isSupported(control)

            guard state.isSupported else {
                updated[control] = state
                continue
            }

            do {
                let range = try device.getRange(for: control)
                state.minimum      = range.minimum
                state.maximum      = range.maximum
                state.resolution   = max(1, range.resolution)
                state.defaultValue = range.defaultValue

                state.currentValue = try device.getValue(for: control)
            } catch {
                state.isSupported = false
                state.error = error.localizedDescription
                print("[UVC] Failed to read \(control.displayName): \(error)")
            }

            updated[control] = state
        }

        // Apply any saved settings on top
        let persistence = SettingsPersistence()
        let saved = persistence.loadAll(cameraID: cameraID)

        for (control, savedValue) in saved {
            if var state = updated[control], state.isSupported {
                let clamped = max(state.minimum, min(state.maximum, savedValue))
                if clamped != state.currentValue {
                    do {
                        try device.setValue(clamped, for: control)
                        state.currentValue = clamped
                        updated[control] = state
                    } catch {
                        print("[UVC] Could not restore \(control.displayName): \(error)")
                    }
                }
            }
        }

        // Read auto-mode state
        let aeSupported = device.isAutoExposureSupported
        var aeEnabled = false
        if aeSupported {
            aeEnabled = (try? device.getAutoExposureMode()).map { $0 != 1 } ?? false
        }

        let wbAutoSupported = device.isWhiteBalanceAutoSupported
        var wbAutoEnabled = false
        if wbAutoSupported {
            wbAutoEnabled = (try? device.getWhiteBalanceAuto()) ?? false
        }

        let finalControls = updated
        Task { @MainActor in
            self.controls = finalControls
            self.autoExposureSupported = aeSupported
            self.autoExposureEnabled = aeEnabled
            self.whiteBalanceAutoSupported = wbAutoSupported
            self.whiteBalanceAutoEnabled = wbAutoEnabled
            self.isLoading = false
        }
    }

    // MARK: - Setting Values

    func setValue(_ value: Int, for control: UVCControl) {
        guard let device = selectedCamera?.uvcDevice else { return }

        // Optimistic UI update
        controls[control]?.currentValue = value

        ioQueue.async { [weak self] in
            do {
                try device.setValue(value, for: control)
                // Persist on success
                if let cameraID = self?.selectedCamera?.id {
                    SettingsPersistence().save(value: value, for: control, cameraID: cameraID)
                }
            } catch {
                print("[UVC] SET_CUR failed for \(control.displayName): \(error)")
                // Revert optimistic update by re-reading
                if let actualValue = try? device.getValue(for: control) {
                    Task { @MainActor in
                        self?.controls[control]?.currentValue = actualValue
                        self?.controls[control]?.error = error.localizedDescription
                    }
                }
            }
        }
    }

    func setAutoExposure(_ enabled: Bool) {
        guard let device = selectedCamera?.uvcDevice, autoExposureSupported else { return }
        autoExposureEnabled = enabled

        ioQueue.async { [weak self] in
            do {
                // 1 = Manual, 8 = Aperture Priority (most cameras use this for "auto")
                try device.setAutoExposureMode(enabled ? 8 : 1)
            } catch {
                print("[UVC] setAutoExposureMode failed: \(error)")
                Task { @MainActor in self?.autoExposureEnabled = !enabled }
            }
        }
    }

    func setWhiteBalanceAuto(_ enabled: Bool) {
        guard let device = selectedCamera?.uvcDevice, whiteBalanceAutoSupported else { return }
        whiteBalanceAutoEnabled = enabled

        ioQueue.async { [weak self] in
            do {
                try device.setWhiteBalanceAuto(enabled)
            } catch {
                print("[UVC] setWhiteBalanceAuto failed: \(error)")
                Task { @MainActor in self?.whiteBalanceAutoEnabled = !enabled }
            }
        }
    }

    func resetToDefaults() {
        for control in UVCControl.allCases {
            if let state = controls[control], state.isSupported {
                setValue(state.defaultValue, for: control)
            }
        }
    }

    func resetControl(_ control: UVCControl) {
        if let state = controls[control], state.isSupported {
            setValue(state.defaultValue, for: control)
        }
    }
}
