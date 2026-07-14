import Foundation
import Observation

/// Bridges UVC camera hardware state to SwiftUI.
/// All IOKit I/O is dispatched on a dedicated serial queue; UI state is updated on the main actor.
@Observable
@MainActor
final class CameraViewModel {
    var selectedCamera: CameraInfo?
    var selectedCameraID: String?
    var showingSettings: Bool = false
    /// Tracks the last explicitly selected camera so it can be auto-reselected on reconnect.
    /// ID may change when plugged into a different port, so we keep the name as a fallback.
    private(set) var lastSelectedCameraID: String?
    private(set) var lastSelectedCameraName: String?
    var controls: [UVCControl: ControlState] = [:]
    var errorMessage: String?
    var isLoading: Bool = false

    var hasSupportedControls: Bool {
        controls.values.contains { $0.isSupported }
    }

    // Auto-mode state
    var autoExposureEnabled: Bool = false
    var autoExposureSupported: Bool = false
    var whiteBalanceAutoEnabled: Bool = false
    var whiteBalanceAutoSupported: Bool = false
    var focusAutoEnabled: Bool = false
    var focusAutoSupported: Bool = false

    // Presets
    var presets: [CameraPreset] = []

    private let ioQueue = DispatchQueue(label: "com.macwebcamcontroller.uvc", qos: .userInitiated)

    init() {
        resetControls()
    }

    // MARK: - Camera Selection

    func selectCamera(_ camera: CameraInfo?) {
        if let camera {
            lastSelectedCameraID = camera.id
            lastSelectedCameraName = camera.name
        }
        selectedCamera = camera
        selectedCameraID = camera?.id
        errorMessage = nil
        resetControls()
        autoExposureEnabled = false
        autoExposureSupported = false
        whiteBalanceAutoEnabled = false
        whiteBalanceAutoSupported = false
        focusAutoEnabled = false
        focusAutoSupported = false

        presets = SettingsPersistence().loadPresets(cameraID: camera?.id ?? "")

        guard let camera, let device = camera.uvcDevice else {
            print("[ViewModel] selectCamera: no UVC device for '\(camera?.name ?? "nil")'")
            return
        }

        print("[ViewModel] selectCamera: '\(camera.name)' PU:\(device.processingUnitID) CT:\(device.cameraTerminalID) puControls:0x\(String(device.supportedPUControls, radix: 16)) ctControls:0x\(String(device.supportedCTControls, radix: 16))")
        isLoading = true
        let cameraID = camera.id
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.loadControls(from: device, cameraID: cameraID)
        }
    }

    // MARK: - Control Loading

    private func resetControls() {
        controls = Dictionary(uniqueKeysWithValues:
            UVCControl.allCases.map { ($0, ControlState()) }
        )
    }

    /// Reads all control values and ranges from the UVC device (runs on ioQueue).
    nonisolated private func loadControls(
        from device: UVCDevice,
        cameraID: String,
        retryCount: Int = 0
    ) {
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

        // Focus Auto is D17 in the Camera Terminal descriptor. Some cameras omit
        // that capability bit even though selector 0x08 works, so also probe the
        // control directly before deciding whether to show the Auto Focus toggle.
        let focusAutoAdvertised = device.isFocusAutoSupported
        let focusAutoValue = try? device.getFocusAuto()
        let focusAutoSupported = focusAutoAdvertised || focusAutoValue != nil
        let focusAutoEnabled = focusAutoValue ?? false

        let finalControls = updated
        let anySupported = finalControls.values.contains { $0.isSupported }
        Task { @MainActor [weak self] in
            guard let self, self.selectedCamera?.id == cameraID else { return }
            self.controls = finalControls
            self.autoExposureSupported = aeSupported
            self.autoExposureEnabled = aeEnabled
            self.whiteBalanceAutoSupported = wbAutoSupported
            self.whiteBalanceAutoEnabled = wbAutoEnabled
            self.focusAutoSupported = focusAutoSupported
            self.focusAutoEnabled = focusAutoEnabled
            self.isLoading = false

            // If every control failed it's almost certainly a timing issue (USB device not
            // fully enumerated yet). Retry once after 1.5 s — covers different-port plug-ins
            // where full re-enumeration takes longer than the initial connect delay.
            if !anySupported, retryCount < 1 {
                print("[ViewModel] All controls unsupported — retrying after delay (timing issue?)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.selectedCamera?.id == cameraID else { return }
                self.isLoading = true
                self.ioQueue.async { [weak self] in
                    self?.loadControls(
                        from: device,
                        cameraID: cameraID,
                        retryCount: retryCount + 1
                    )
                }
            }
        }
    }

    // MARK: - Setting Values

    func setValue(_ value: Int, for control: UVCControl) {
        guard let camera = selectedCamera, let device = camera.uvcDevice else { return }

        // Optimistic UI update
        controls[control]?.currentValue = value

        // Capture Sendable values before crossing actor boundary
        let cameraID = camera.id
        ioQueue.async { [weak self] in
            do {
                try device.setValue(value, for: control)
                print("[UVC] SET_CUR \(control.displayName) = \(value) OK")
                SettingsPersistence().save(value: value, for: control, cameraID: cameraID)
                Task { @MainActor [weak self] in
                    guard let self, self.selectedCamera?.id == cameraID else { return }
                    self.controls[control]?.error = nil
                }
            } catch {
                print("[UVC] SET_CUR \(control.displayName) = \(value) FAILED: \(error)")

                // When a control rejects SET_CUR, re-check whether its auto mode is actually
                // on — some camera firmware reports auto disabled via GET_CUR but still locks
                // the control. Detecting this lets us self-correct the toggle state and show
                // a clear message instead of a raw USB error.
                var autoLocked = false
                switch control {
                case .whiteBalanceTemperature:
                    if let isAuto = try? device.getWhiteBalanceAuto(), isAuto {
                        autoLocked = true
                        Task { @MainActor [weak self] in
                            guard let self, self.selectedCamera?.id == cameraID else { return }
                            self.whiteBalanceAutoEnabled = true
                        }
                    }
                case .exposureAbsolute:
                    if let mode = try? device.getAutoExposureMode(), mode != 1 {
                        autoLocked = true
                        Task { @MainActor [weak self] in
                            guard let self, self.selectedCamera?.id == cameraID else { return }
                            self.autoExposureEnabled = true
                        }
                    }
                case .focusAbsolute:
                    if let isAuto = try? device.getFocusAuto(), isAuto {
                        autoLocked = true
                        Task { @MainActor [weak self] in
                            guard let self, self.selectedCamera?.id == cameraID else { return }
                            self.focusAutoSupported = true
                            self.focusAutoEnabled = true
                        }
                    }
                default:
                    break
                }

                // Revert optimistic update and show an appropriate error message
                let errorMessage = autoLocked
                    ? "Disable auto mode first to adjust manually."
                    : "Set failed: \(error.localizedDescription)"
                if let actualValue = try? device.getValue(for: control) {
                    if actualValue == value && !autoLocked {
                        // Camera applied the value despite the USB error (firmware quirk) — treat as success.
                        SettingsPersistence().save(value: value, for: control, cameraID: cameraID)
                        Task { @MainActor [weak self] in
                            guard let self, self.selectedCamera?.id == cameraID else { return }
                            self.controls[control]?.currentValue = actualValue
                            self.controls[control]?.error = nil
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            guard let self, self.selectedCamera?.id == cameraID else { return }
                            self.controls[control]?.currentValue = actualValue
                            self.controls[control]?.error = errorMessage
                        }
                    }
                }
            }
        }
    }

    func setAutoExposure(_ enabled: Bool) {
        guard let camera = selectedCamera,
              let device = camera.uvcDevice,
              autoExposureSupported else { return }
        autoExposureEnabled = enabled
        let cameraID = camera.id

        ioQueue.async { [weak self] in
            do {
                // 1 = Manual, 8 = Aperture Priority (most cameras use this for "auto")
                try device.setAutoExposureMode(enabled ? 8 : 1)
            } catch {
                print("[UVC] setAutoExposureMode failed: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, self.selectedCamera?.id == cameraID else { return }
                    self.autoExposureEnabled = !enabled
                }
            }
        }
    }

    func setWhiteBalanceAuto(_ enabled: Bool) {
        guard let camera = selectedCamera,
              let device = camera.uvcDevice,
              whiteBalanceAutoSupported else { return }
        whiteBalanceAutoEnabled = enabled
        let cameraID = camera.id

        ioQueue.async { [weak self] in
            do {
                try device.setWhiteBalanceAuto(enabled)
            } catch {
                print("[UVC] setWhiteBalanceAuto failed: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, self.selectedCamera?.id == cameraID else { return }
                    self.whiteBalanceAutoEnabled = !enabled
                }
            }
        }
    }

    func setFocusAuto(_ enabled: Bool) {
        guard let camera = selectedCamera,
              let device = camera.uvcDevice,
              focusAutoSupported else { return }
        focusAutoEnabled = enabled
        let cameraID = camera.id

        ioQueue.async { [weak self] in
            do {
                try device.setFocusAuto(enabled)
            } catch {
                print("[UVC] setFocusAuto failed: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, self.selectedCamera?.id == cameraID else { return }
                    self.focusAutoEnabled = !enabled
                }
            }
        }
    }

    func resetToDefaults() {
        for control in UVCControl.allCases {
            guard let state = controls[control], state.isSupported else { continue }
            guard !control.isManagedAutomatically(
                autoExposure: autoExposureEnabled,
                autoWhiteBalance: whiteBalanceAutoEnabled,
                autoFocus: focusAutoEnabled
            ) else { continue }
            setValue(state.defaultValue, for: control)
        }
    }

    func resetControl(_ control: UVCControl) {
        guard let state = controls[control], state.isSupported else { return }
        guard !control.isManagedAutomatically(
            autoExposure: autoExposureEnabled,
            autoWhiteBalance: whiteBalanceAutoEnabled,
            autoFocus: focusAutoEnabled
        ) else { return }
        setValue(state.defaultValue, for: control)
    }

    // MARK: - Presets

    private func currentPresetValues() -> [String: Int] {
        controls.reduce(into: [String: Int]()) { values, entry in
            let (control, state) = entry
            guard state.isSupported,
                  !control.isManagedAutomatically(
                      autoExposure: autoExposureEnabled,
                      autoWhiteBalance: whiteBalanceAutoEnabled,
                      autoFocus: focusAutoEnabled
                  ) else { return }
            values[control.rawValue] = state.currentValue
        }
    }

    func savePreset(name: String) {
        guard let cameraID = selectedCamera?.id else { return }
        let preset = CameraPreset(
            name: name,
            values: currentPresetValues(),
            autoExposureEnabled: autoExposureSupported ? autoExposureEnabled : nil,
            whiteBalanceAutoEnabled: whiteBalanceAutoSupported ? whiteBalanceAutoEnabled : nil,
            focusAutoEnabled: focusAutoSupported ? focusAutoEnabled : nil
        )
        presets.append(preset)
        SettingsPersistence().savePresets(presets, cameraID: cameraID)
    }

    func applyPreset(_ preset: CameraPreset) {
        // Disable automatic modes before applying their manual values. All USB
        // operations use the same serial queue, so this ordering also reaches the
        // camera in the correct sequence. Automatic modes are enabled afterwards,
        // allowing the saved manual baseline to be restored first.
        if preset.autoExposureEnabled == false, autoExposureSupported {
            setAutoExposure(false)
        }
        if preset.whiteBalanceAutoEnabled == false, whiteBalanceAutoSupported {
            setWhiteBalanceAuto(false)
        }
        if preset.focusAutoEnabled == false, focusAutoSupported {
            setFocusAuto(false)
        }

        // A nil mode is from an older preset. In that case retain the current
        // mode and avoid writing a manual value while that mode is active.
        let effectiveAutoExposure = preset.autoExposureEnabled ?? autoExposureEnabled
        let effectiveAutoWhiteBalance = preset.whiteBalanceAutoEnabled ?? whiteBalanceAutoEnabled
        let effectiveAutoFocus = preset.focusAutoEnabled ?? focusAutoEnabled

        for (rawValue, value) in preset.values {
            guard let control = UVCControl(rawValue: rawValue) else { continue }
            guard !control.isManagedAutomatically(
                autoExposure: effectiveAutoExposure,
                autoWhiteBalance: effectiveAutoWhiteBalance,
                autoFocus: effectiveAutoFocus
            ) else { continue }
            setValue(value, for: control)
        }

        if preset.autoExposureEnabled == true, autoExposureSupported {
            setAutoExposure(true)
        }
        if preset.whiteBalanceAutoEnabled == true, whiteBalanceAutoSupported {
            setWhiteBalanceAuto(true)
        }
        if preset.focusAutoEnabled == true, focusAutoSupported {
            setFocusAuto(true)
        }
    }

    func updatePreset(_ preset: CameraPreset) {
        guard let cameraID = selectedCamera?.id,
              let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].values = currentPresetValues()
        presets[index].autoExposureEnabled = autoExposureSupported ? autoExposureEnabled : nil
        presets[index].whiteBalanceAutoEnabled = whiteBalanceAutoSupported ? whiteBalanceAutoEnabled : nil
        presets[index].focusAutoEnabled = focusAutoSupported ? focusAutoEnabled : nil
        SettingsPersistence().savePresets(presets, cameraID: cameraID)
    }

    func deletePreset(_ preset: CameraPreset) {
        guard let cameraID = selectedCamera?.id else { return }
        presets.removeAll { $0.id == preset.id }
        SettingsPersistence().savePresets(presets, cameraID: cameraID)
    }
}
