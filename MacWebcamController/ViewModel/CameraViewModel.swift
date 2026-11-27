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
    /// A serial-backed identity permits safe reselection across USB ports.
    private(set) var lastSelectedCameraID: String?
    private(set) var lastSelectedCameraName: String?
    private(set) var lastSelectedPhysicalCameraID: String?
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

    private let ioQueue: DispatchQueue

    private var loadRequest: CameraLoadRequest?
    private let persistence: SettingsPersistence

    init(persistence: SettingsPersistence = SettingsPersistence(),
         ioQueue: DispatchQueue = DispatchQueue(label: "com.macwebcamcontroller.uvc", qos: .userInitiated)) {
        self.ioQueue = ioQueue
        self.persistence = persistence
        let (savedID, savedName, physicalID) = persistence.loadLastSelectedCamera()
        self.lastSelectedCameraID = savedID
        self.lastSelectedCameraName = savedName
        self.lastSelectedPhysicalCameraID = physicalID
        resetControls()
    }

    // MARK: - Camera Selection

    func selectCamera(_ camera: CameraInfo?) {
        loadRequest?.cancel()
        let request = CameraLoadRequest()
        loadRequest = request
        isLoading = false
        if let camera {
            lastSelectedCameraID = camera.id
            lastSelectedCameraName = camera.name
            lastSelectedPhysicalCameraID = camera.uvcDevice?.persistentIdentity
            persistence.saveLastSelectedCamera(id: camera.id, name: camera.name,
                                               physicalID: lastSelectedPhysicalCameraID)
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

        presets = persistence.loadPresets(cameraID: camera?.id ?? "")

        guard let camera, let device = camera.uvcDevice else {
            print("[ViewModel] selectCamera: no UVC device for '\(camera?.name ?? "nil")'")
            return
        }

        print("[ViewModel] selectCamera: '\(camera.name)' PU:\(device.processingUnitID) CT:\(device.cameraTerminalID) puControls:0x\(String(device.supportedPUControls, radix: 16)) ctControls:0x\(String(device.supportedCTControls, radix: 16))")
        isLoading = true
        let cameraID = camera.id
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.loadControls(from: device, cameraID: cameraID, request: request)
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
        from device: any CameraControlling,
        cameraID: String,
        request: CameraLoadRequest,
        retryCount: Int = 0
    ) {
        var updated: [UVCControl: ControlState] = [:]

        guard !request.isCancelled else { return }
        // Probe directly as well: some cameras omit valid descriptor capability bits.
        let aeMode = try? device.getAutoExposureMode()
        let aeSupported = device.isAutoExposureSupported || aeMode != nil
        let aeEnabled = aeMode.map { $0 != 1 } ?? aeSupported
        let wbMode = try? device.getWhiteBalanceAuto()
        let wbAutoSupported = device.isWhiteBalanceAutoSupported || wbMode != nil
        let wbAutoEnabled = wbMode ?? wbAutoSupported
        let focusMode = try? device.getFocusAuto()
        let focusAutoSupported = device.isFocusAutoSupported || focusMode != nil
        let focusAutoEnabled = focusMode ?? focusAutoSupported

        for control in UVCControl.allCases {
            guard !request.isCancelled else { return }
            var state = ControlState()
            state.isSupported = device.isSupported(control)

            guard state.isSupported else {
                updated[control] = state
                continue
            }

            // Mandatory bounds must be readable; optional metadata has safe fallbacks.
            do {
                let range = try device.getRange(for: control)
                state.range = range

                let hardwareCurrent = try device.getValue(for: control)
                state.currentValue = hardwareCurrent
                let isAutomatic = control.isManagedAutomatically(
                    autoExposure: aeEnabled, autoWhiteBalance: wbAutoEnabled,
                    autoFocus: focusAutoEnabled
                )
                guard !request.isCancelled else { return }
                if let persisted = persistence.load(for: control, cameraID: cameraID),
                   !isAutomatic {
                    let target = range.normalized(persisted)
                    if target != hardwareCurrent {
                        do {
                            try device.setValue(target, for: control)
                            // Some cameras quantize or silently ignore a SET_CUR.
                            state.currentValue = try device.getValue(for: control)
                            persistence.save(value: state.currentValue, for: control, cameraID: cameraID)
                        } catch {
                            state.currentValue = (try? device.getValue(for: control)) ?? hardwareCurrent
                            state.error = "Could not restore saved value: \(error.localizedDescription)"
                        }
                    }
                } else if persistence.load(for: control, cameraID: cameraID) == nil, !isAutomatic {
                    persistence.save(value: hardwareCurrent, for: control, cameraID: cameraID)
                }
            } catch {
                print("[UVC] \(control.rawValue) range probe failed: \(error)")
                state.isSupported = false
            }

            updated[control] = state
        }

        // If every single control failed on the first attempt, the camera's USB endpoint
        // may still be initializing after plug-in. Wait briefly and retry once.
        let anySupported = updated.values.contains { $0.isSupported }
        if !anySupported && retryCount == 0 {
            print("[UVC] All controls failed on first attempt — retrying in 1.5s...")
            ioQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard !request.isCancelled else { return }
                self?.loadControls(from: device, cameraID: cameraID, request: request, retryCount: 1)
            }
            return
        }

        let loadedControls = updated
        Task { @MainActor [weak self] in
            guard let self, !request.isCancelled, self.loadRequest === request else { return }
            self.controls = loadedControls
            self.autoExposureSupported = aeSupported
            self.autoExposureEnabled = aeEnabled
            self.whiteBalanceAutoSupported = wbAutoSupported
            self.whiteBalanceAutoEnabled = wbAutoEnabled
            self.focusAutoSupported = focusAutoSupported
            self.focusAutoEnabled = focusAutoEnabled
            self.isLoading = false
        }
    }

    // MARK: - Control Modification

    func setValue(_ value: Int, for control: UVCControl) {
        guard let camera = selectedCamera,
              let device = camera.uvcDevice,
              let state = controls[control],
              state.isSupported else { return }

        guard !control.isManagedAutomatically(
            autoExposure: autoExposureEnabled,
            autoWhiteBalance: whiteBalanceAutoEnabled,
            autoFocus: focusAutoEnabled
        ) else { return }
        let value = state.range.normalized(value)

        // Optimistic UI update
        controls[control]?.currentValue = value
        controls[control]?.error = nil
        let cameraID = camera.id
        let persistence = self.persistence
        let request = loadRequest

        ioQueue.async { [weak self] in
            guard request?.isCancelled == false else { return }
            do {
                try device.setValue(value, for: control)
                persistence.save(value: value, for: control, cameraID: cameraID)
            } catch {
                print("[UVC] setValue failed for \(control.rawValue): \(error)")

                // Check whether an automatic mode is locking this control
                var autoLocked = false
                switch control {
                case .whiteBalanceTemperature:
                    if let isAuto = try? device.getWhiteBalanceAuto(), isAuto {
                        autoLocked = true
                        Task { @MainActor [weak self] in
                            guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
                            self.whiteBalanceAutoEnabled = true
                        }
                    }
                case .exposureAbsolute:
                    if let mode = try? device.getAutoExposureMode(), mode != 1 {
                        autoLocked = true
                        Task { @MainActor [weak self] in
                            guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
                            self.autoExposureEnabled = true
                        }
                    }
                case .focusAbsolute:
                    if let isAuto = try? device.getFocusAuto(), isAuto {
                        autoLocked = true
                        Task { @MainActor [weak self] in
                            guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
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
                        persistence.save(value: value, for: control, cameraID: cameraID)
                        Task { @MainActor [weak self] in
                            guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
                            self.controls[control]?.currentValue = actualValue
                            self.controls[control]?.error = nil
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
                            self.controls[control]?.currentValue = actualValue
                            self.controls[control]?.error = errorMessage
                        }
                    }
                } else {
                    Task { @MainActor [weak self] in
                        guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
                        self.controls[control]?.error = errorMessage
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
        let request = loadRequest

        ioQueue.async { [weak self] in
            guard request?.isCancelled == false else { return }
            do {
                try device.setAutoExposure(enabled: enabled)
            } catch {
                print("[UVC] setAutoExposure failed: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
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
        let request = loadRequest

        ioQueue.async { [weak self] in
            guard request?.isCancelled == false else { return }
            do {
                try device.setWhiteBalanceAuto(enabled)
            } catch {
                print("[UVC] setWhiteBalanceAuto failed: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
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
        let request = loadRequest

        ioQueue.async { [weak self] in
            guard request?.isCancelled == false else { return }
            do {
                try device.setFocusAuto(enabled)
            } catch {
                print("[UVC] setFocusAuto failed: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, request?.isCancelled == false, self.selectedCamera?.id == cameraID else { return }
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
        persistence.savePresets(presets, cameraID: cameraID)
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
        persistence.savePresets(presets, cameraID: cameraID)
    }

    func deletePreset(_ preset: CameraPreset) {
        guard let cameraID = selectedCamera?.id else { return }
        presets.removeAll { $0.id == preset.id }
        persistence.savePresets(presets, cameraID: cameraID)
    }
}

/// Cancellation is read on the USB queue and written by the main actor.
private final class CameraLoadRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
