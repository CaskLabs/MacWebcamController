import Foundation

/// Saves and restores per-camera UVC control values using UserDefaults.
/// Key format: "camera.<uniqueID>.<control.rawValue>"
struct SettingsPersistence {
    private let defaults = UserDefaults.standard

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
}
