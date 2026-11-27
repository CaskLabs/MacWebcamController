import Foundation

/// State for a single UVC control — current value, range, and capabilities.
struct ControlState: Sendable {
    var range: UVCControlRange {
        get {
            UVCControlRange(minimum: minimum, maximum: maximum,
                            resolution: resolution, defaultValue: defaultValue)
        }
        set {
            minimum = newValue.minimum
            maximum = newValue.maximum
            resolution = max(1, newValue.resolution)
            defaultValue = newValue.defaultValue
        }
    }

    var currentValue: Int = 0
    var minimum: Int = 0
    var maximum: Int = 1
    var resolution: Int = 1
    var defaultValue: Int = 0
    var isSupported: Bool = false
    var isAutoSupported: Bool = false
    var isAutoEnabled: Bool = false
    var error: String?
}
