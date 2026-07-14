import Foundation

// MARK: - Camera Preset

struct CameraPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var values: [String: Int]  // UVCControl.rawValue → Int
    var autoExposureEnabled: Bool?
    var whiteBalanceAutoEnabled: Bool?
    var focusAutoEnabled: Bool?

    init(name: String, values: [String: Int],
         autoExposureEnabled: Bool? = nil,
         whiteBalanceAutoEnabled: Bool? = nil,
         focusAutoEnabled: Bool? = nil) {
        self.id = UUID()
        self.name = name
        self.values = values
        self.autoExposureEnabled = autoExposureEnabled
        self.whiteBalanceAutoEnabled = whiteBalanceAutoEnabled
        self.focusAutoEnabled = focusAutoEnabled
    }
}

// MARK: - Settings Persistence

/// Saves and restores per-camera UVC control values using UserDefaults.
/// Key format: "camera.<uniqueID>.<control.rawValue>"
struct SettingsPersistence {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for control: UVCControl, cameraID: String) -> String {
        "camera.\(cameraID).\(control.rawValue)"
    }

    func save(value: Int, for control: UVCControl, cameraID: String) {
        defaults.set(value, forKey: key(for: control, cameraID: cameraID))
    }

    func load(for control: UVCControl, cameraID: String) -> Int? {
        let k = key(for: control, cameraID: cameraID)
        guard defaults.object(forKey: k) != nil else { return nil }
        return defaults.integer(forKey: k)
    }

    func saveAll(controls: [UVCControl: Int], cameraID: String) {
        for (control, value) in controls {
            save(value: value, for: control, cameraID: cameraID)
        }
    }

    func loadAll(cameraID: String) -> [UVCControl: Int] {
        var result: [UVCControl: Int] = [:]
        for control in UVCControl.allCases {
            if let value = load(for: control, cameraID: cameraID) {
                result[control] = value
            }
        }
        return result
    }

    func clearAll(cameraID: String) {
        for control in UVCControl.allCases {
            defaults.removeObject(forKey: key(for: control, cameraID: cameraID))
        }
    }

    /// Copies persisted values and presets when the same camera reconnects with a
    /// different AVFoundation ID, for example after moving it to another USB port.
    /// The source data is retained so reconnecting on the original port also works.
    func migrateCameraData(from oldCameraID: String, to newCameraID: String) {
        guard !oldCameraID.isEmpty,
              !newCameraID.isEmpty,
              oldCameraID != newCameraID else { return }

        for control in UVCControl.allCases {
            guard let value = load(for: control, cameraID: oldCameraID) else { continue }
            save(value: value, for: control, cameraID: newCameraID)
        }

        let oldPresets = loadPresets(cameraID: oldCameraID)
        if !oldPresets.isEmpty {
            savePresets(oldPresets, cameraID: newCameraID)
        }
    }

    // MARK: - Named Presets

    private func presetsKey(for cameraID: String) -> String { "presets.\(cameraID)" }

    func loadPresets(cameraID: String) -> [CameraPreset] {
        guard let data = defaults.data(forKey: presetsKey(for: cameraID)),
              let presets = try? JSONDecoder().decode([CameraPreset].self, from: data)
        else { return [] }
        return presets
    }

    func savePresets(_ presets: [CameraPreset], cameraID: String) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey(for: cameraID))
    }
}
