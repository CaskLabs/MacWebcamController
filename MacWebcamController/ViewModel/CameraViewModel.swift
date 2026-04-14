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

    // Presets
    var presets: [CameraPreset] = []

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

        presets = SettingsPersistence().loadPresets(cameraID: camera?.id ?? "")

        guard let camera, let device = camera.uvcDevice else {
            print("[ViewModel] selectCamera: no UVC device for '\(camera?.name ?? "nil")'")
            return
        }

        print("[ViewModel] selectCamera: '\(camera.name)' PU:\(device.processingUnitID) CT:\(device.cameraTerminalID) puControls:0x\(String(device.supportedPUControls, radix: 16)) ctControls:0x\(String(device.supportedCTControls, radix: 16))")
        isLoading = true
        let cameraID = camera.id
        ioQueue.async { [weak self] in
            self?.loadControls(from: device, cameraID: cameraID)
        }
    }

    // MARK: - Control Loading

    private func resetControls() {
        controls = Dictionary(uniqueKeysWithValues:
            UVCControl.allCases.map { ($0, ControlState()) }
        )
    }

    /// Reads all control values and ranges from the UVC device (runs on ioQueue).
    nonisolated private func loadControls(from device: UVCDevice, cameraID: String) {
        var updated: [UVCControl: ControlState] = [:]

        for control in UVCControl.allCases {
            var state = ControlState()
            state.isSupported = device.isSupported(control)

            guard state.isSupported else {
                updated[control] = state
                continue
            }

            // Try to get minimum first — if this fails the control is truly unsupported.
            let minimum: Int
            do {
                minimum = try device.getValue(for: control, request: .getMinimum)
            } catch {
                state.isSupported = false
                print("[UVC] \(control.displayName) not supported (GET_MIN failed): \(error)")
                updated[control] = state
                continue
            }

            // GET_MAX, GET_RES, GET_DEF — use fallbacks if individual requests fail.
            let maximum      = (try? device.getValue(for: control, request: .getMaximum)) ?? minimum + 100
            let resolution   = (try? device.getValue(for: control, request: .getResolution)) ?? 1
            let defaultValue = (try? device.getValue(for: control, request: .getDefault)) ?? ((minimum + maximum) / 2)
            let current      = (try? device.getValue(for: control)) ?? defaultValue

            // Degenerate range means the camera responded but doesn't actually
            // support adjusting this control (e.g. Sony ZV-E10 returns 6/6).
            if maximum <= minimum {
                state.isSupported = false
                print("[UVC] \(control.displayName) degenerate range [\(minimum)…\(maximum)], marking unsupported")
                updated[control] = state
                continue
            }

            state.minimum      = minimum
            state.maximum      = maximum
            state.resolution   = max(1, resolution)
            state.defaultValue = defaultValue
            state.currentValue = current

            print("[UVC] \(control.displayName): min=\(minimum) max=\(maximum) cur=\(current)")
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

        let cameraID = selectedCamera?.id
        ioQueue.async { [weak self] in
            do {
                try device.setValue(value, for: control)
                print("[UVC] SET_CUR \(control.displayName) = \(value) OK")
                if let cameraID {
                    SettingsPersistence().save(value: value, for: control, cameraID: cameraID)
                }
            } catch {
                print("[UVC] SET_CUR \(control.displayName) = \(value) FAILED: \(error)")
                // Revert optimistic update by re-reading
                if let actualValue = try? device.getValue(for: control) {
                    Task { @MainActor in
                        self?.controls[control]?.currentValue = actualValue
                        self?.controls[control]?.error = "Set failed: \(error.localizedDescription)"
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

    // MARK: - Presets

    func savePreset(name: String) {
        guard let cameraID = selectedCamera?.id else { return }
        let values = controls.compactMapValues { state -> Int? in
            state.isSupported ? state.currentValue : nil
        }.reduce(into: [String: Int]()) { dict, pair in
            dict[pair.key.rawValue] = pair.value
        }
        let preset = CameraPreset(
            name: name,
            values: values,
            autoExposureEnabled: autoExposureSupported ? autoExposureEnabled : nil,
            whiteBalanceAutoEnabled: whiteBalanceAutoSupported ? whiteBalanceAutoEnabled : nil
        )
        presets.append(preset)
        SettingsPersistence().savePresets(presets, cameraID: cameraID)
    }

    func applyPreset(_ preset: CameraPreset) {
        for (rawValue, value) in preset.values {
            guard let control = UVCControl(rawValue: rawValue) else { continue }
            setValue(value, for: control)
        }
        if let ae = preset.autoExposureEnabled, autoExposureSupported {
            setAutoExposure(ae)
        }
        if let wb = preset.whiteBalanceAutoEnabled, whiteBalanceAutoSupported {
            setWhiteBalanceAuto(wb)
        }
    }

    func updatePreset(_ preset: CameraPreset) {
        guard let cameraID = selectedCamera?.id,
              let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let values = controls.reduce(into: [String: Int]()) { dict, pair in
            if pair.value.isSupported { dict[pair.key.rawValue] = pair.value.currentValue }
        }
        presets[index].values = values
        presets[index].autoExposureEnabled = autoExposureSupported ? autoExposureEnabled : nil
        presets[index].whiteBalanceAutoEnabled = whiteBalanceAutoSupported ? whiteBalanceAutoEnabled : nil
        SettingsPersistence().savePresets(presets, cameraID: cameraID)
    }

    func deletePreset(_ preset: CameraPreset) {
        guard let cameraID = selectedCamera?.id else { return }
        presets.removeAll { $0.id == preset.id }
        SettingsPersistence().savePresets(presets, cameraID: cameraID)
    }
}
