import Foundation

/// State for a single UVC control — current value, range, and capabilities.
struct ControlState: Sendable {
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
