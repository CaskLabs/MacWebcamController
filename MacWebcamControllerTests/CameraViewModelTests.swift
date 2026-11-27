import XCTest
import Observation
@testable import MacWebcamController

final class CameraViewModelTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testSwitchingToPreviewOnlyCameraClearsLoadingAndCancelsQueuedRestore() async {
        let suite = "CameraViewModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SettingsPersistence(defaults: defaults)
        persistence.save(value: 18, for: .brightness, cameraID: "old")
        let queue = DispatchQueue(label: suite)
        let model = CameraViewModel(persistence: persistence, ioQueue: queue)
        let device = TestCameraDevice()
        queue.suspend()
        model.selectCamera(camera("old", device: device))
        XCTAssertTrue(model.isLoading)
        model.selectCamera(camera("preview", device: nil))
        XCTAssertFalse(model.isLoading)
        queue.resume()
        await drain(queue)
        XCTAssertEqual(model.selectedCameraID, "preview")
        XCTAssertFalse(model.hasSupportedControls)
        XCTAssertTrue(device.writes.isEmpty)
    }

    @MainActor
    func testFailedRestoreKeepsHardwareValueAndReportsError() async {
        let suite = "CameraViewModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SettingsPersistence(defaults: defaults)
        persistence.save(value: 18, for: .brightness, cameraID: "camera")
        let model = CameraViewModel(persistence: persistence)
        let device = TestCameraDevice(writeBehavior: .fail)
        await load(model, device: device)
        XCTAssertEqual(model.controls[.brightness]?.currentValue, 8)
        XCTAssertNotNil(model.controls[.brightness]?.error)
        XCTAssertEqual(persistence.load(for: .brightness, cameraID: "camera"), 18)
    }

    @MainActor
    func testIgnoredRestoreUsesReadbackRatherThanRequestedValue() async {
        let suite = "CameraViewModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SettingsPersistence(defaults: defaults)
        persistence.save(value: 18, for: .brightness, cameraID: "camera")
        let model = CameraViewModel(persistence: persistence)
        await load(model, device: TestCameraDevice(writeBehavior: .ignore))
        XCTAssertEqual(model.controls[.brightness]?.currentValue, 8)
        XCTAssertEqual(persistence.load(for: .brightness, cameraID: "camera"), 8)
    }

    @MainActor
    func testRestoreSnapsToHardwareGrid() async {
        let suite = "CameraViewModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SettingsPersistence(defaults: defaults)
        persistence.save(value: 17, for: .brightness, cameraID: "camera")
        let model = CameraViewModel(persistence: persistence)
        let device = TestCameraDevice()
        await load(model, device: device)
        XCTAssertEqual(device.writes, [18])
        XCTAssertEqual(model.controls[.brightness]?.currentValue, 18)
    }

    @MainActor
    func testUnadvertisedAutofocusIsDetectedAndManualRestoreIsSkipped() async {
        let suite = "CameraViewModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SettingsPersistence(defaults: defaults)
        persistence.save(value: 18, for: .focusAbsolute, cameraID: "camera")
        let model = CameraViewModel(persistence: persistence)
        let device = TestCameraDevice(control: .focusAbsolute, focusAuto: true)
        await load(model, device: device)
        XCTAssertTrue(model.focusAutoSupported)
        XCTAssertTrue(model.focusAutoEnabled)
        XCTAssertEqual(model.controls[.focusAbsolute]?.currentValue, 8)
        XCTAssertTrue(device.writes.isEmpty)
    }

    @MainActor
    private func load(_ model: CameraViewModel, device: TestCameraDevice) async {
        model.selectCamera(camera("camera", device: device))
        let loaded = expectation(description: "Camera controls loaded")
        withObservationTracking {
            _ = model.isLoading
        } onChange: {
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
    }

    private func camera(_ id: String, device: (any CameraControlling)?) -> CameraInfo {
        CameraInfo(id: id, name: "Test Camera", modelID: "", locationID: 1,
                   vendorID: 1, productID: 1, uvcDevice: device)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

/// Immutable configuration, with hardware value and write history protected by a lock.
private final class TestCameraDevice: CameraControlling, @unchecked Sendable {
    enum WriteBehavior { case apply, ignore, fail }
    enum TestError: Error { case unsupported, rejected }
    let identity = "test-device"
    let persistentIdentity: String? = nil
    let processingUnitID: UInt8 = 1
    let cameraTerminalID: UInt8 = 2
    let supportedPUControls: UInt32 = 1
    let supportedCTControls: UInt32 = 0
    let isAutoExposureSupported = false
    let isWhiteBalanceAutoSupported = false
    let isFocusAutoSupported = false
    private let control: UVCControl
    private let focusAuto: Bool?
    private let writeBehavior: WriteBehavior
    private let lock = NSLock()
    private var value = 8
    private var history: [Int] = []

    init(control: UVCControl = .brightness, focusAuto: Bool? = nil,
         writeBehavior: WriteBehavior = .apply) {
        self.control = control
        self.focusAuto = focusAuto
        self.writeBehavior = writeBehavior
    }

    var writes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    func isSupported(_ control: UVCControl) -> Bool { control == self.control }
    func getRange(for control: UVCControl) throws -> UVCControlRange {
        UVCControlRange(minimum: 3, maximum: 23, resolution: 5, defaultValue: 8)
    }
    func getValue(for control: UVCControl, request: UVCRequest) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func setValue(_ value: Int, for control: UVCControl) throws {
        lock.lock()
        defer { lock.unlock() }
        history.append(value)
        switch writeBehavior {
        case .apply: self.value = value
        case .ignore: break
        case .fail: throw TestError.rejected
        }
    }
    func getAutoExposureMode() throws -> Int { throw TestError.unsupported }
    func getWhiteBalanceAuto() throws -> Bool { throw TestError.unsupported }
    func getFocusAuto() throws -> Bool {
        guard let focusAuto else { throw TestError.unsupported }
        return focusAuto
    }
    func setAutoExposure(enabled: Bool) throws { throw TestError.unsupported }
    func setWhiteBalanceAuto(_ enabled: Bool) throws { throw TestError.unsupported }
    func setFocusAuto(_ enabled: Bool) throws { throw TestError.unsupported }
}
