import XCTest
@testable import MacWebcamController

final class SettingsPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var persistence: SettingsPersistence!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        persistence = SettingsPersistence(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        persistence = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavesLoadsAndClearsControlValuesPerCamera() {
        persistence.save(value: -12, for: .brightness, cameraID: "camera-a")

        XCTAssertEqual(persistence.load(for: .brightness, cameraID: "camera-a"), -12)
        XCTAssertNil(persistence.load(for: .brightness, cameraID: "camera-b"))

        persistence.clearAll(cameraID: "camera-a")
        XCTAssertNil(persistence.load(for: .brightness, cameraID: "camera-a"))
    }

    func testMigratesValuesAndPresetsWithoutDeletingSource() throws {
        persistence.save(value: 42, for: .contrast, cameraID: "old-port")
        persistence.savePresets([
            CameraPreset(name: "Desk", values: [UVCControl.contrast.rawValue: 42])
        ], cameraID: "old-port")

        persistence.migrateCameraData(from: "old-port", to: "new-port")

        XCTAssertEqual(persistence.load(for: .contrast, cameraID: "new-port"), 42)
        XCTAssertEqual(persistence.load(for: .contrast, cameraID: "old-port"), 42)
        let migrated = persistence.loadPresets(cameraID: "new-port")
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.name, "Desk")
        XCTAssertEqual(migrated.first?.values[UVCControl.contrast.rawValue], 42)
    }

    func testPresetRoundTripPreservesAllAutoModes() throws {
        let preset = CameraPreset(
            name: "Automatic",
            values: [UVCControl.brightness.rawValue: 12],
            autoExposureEnabled: true,
            whiteBalanceAutoEnabled: true,
            focusAutoEnabled: true
        )

        persistence.savePresets([preset], cameraID: "camera-a")

        let loaded = try XCTUnwrap(persistence.loadPresets(cameraID: "camera-a").first)
        XCTAssertEqual(loaded.autoExposureEnabled, true)
        XCTAssertEqual(loaded.whiteBalanceAutoEnabled, true)
        XCTAssertEqual(loaded.focusAutoEnabled, true)
    }

    func testLoadsLegacyPresetWithoutFocusAutoMode() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [[
            "id": id.uuidString,
            "name": "Legacy",
            "values": [UVCControl.focusAbsolute.rawValue: 25],
            "autoExposureEnabled": true,
            "whiteBalanceAutoEnabled": true
        ]])
        defaults.set(data, forKey: "presets.camera-a")

        let loaded = try XCTUnwrap(persistence.loadPresets(cameraID: "camera-a").first)
        XCTAssertEqual(loaded.id, id)
        XCTAssertNil(loaded.focusAutoEnabled)
    }

    func testAutomaticModesIdentifyOnlyTheirManualControls() {
        XCTAssertTrue(UVCControl.exposureAbsolute.isManagedAutomatically(
            autoExposure: true, autoWhiteBalance: false, autoFocus: false
        ))
        XCTAssertTrue(UVCControl.gain.isManagedAutomatically(
            autoExposure: true, autoWhiteBalance: false, autoFocus: false
        ))
        XCTAssertTrue(UVCControl.backlightCompensation.isManagedAutomatically(
            autoExposure: true, autoWhiteBalance: false, autoFocus: false
        ))
        XCTAssertTrue(UVCControl.whiteBalanceTemperature.isManagedAutomatically(
            autoExposure: false, autoWhiteBalance: true, autoFocus: false
        ))
        XCTAssertTrue(UVCControl.focusAbsolute.isManagedAutomatically(
            autoExposure: false, autoWhiteBalance: false, autoFocus: true
        ))
        XCTAssertFalse(UVCControl.brightness.isManagedAutomatically(
            autoExposure: true, autoWhiteBalance: true, autoFocus: true
        ))
    }

    func testSavesAndLoadsLastSelectedCamera() {
        let initial = persistence.loadLastSelectedCamera()
        XCTAssertNil(initial.id)
        XCTAssertNil(initial.name)

        persistence.saveLastSelectedCamera(id: "camera-xyz", name: "Logitech Brio")
        let loaded = persistence.loadLastSelectedCamera()
        XCTAssertEqual(loaded.id, "camera-xyz")
        XCTAssertEqual(loaded.name, "Logitech Brio")
    }
    func testMigrationPreservesTargetValuesAndMergesPresetsIdempotently() {
        let source = CameraPreset(name: "Source", values: ["brightness": 2])
        var target = source
        target.name = "Edited on target"
        let extra = CameraPreset(name: "Extra", values: [:])
        persistence.save(value: 12, for: .brightness, cameraID: "old")
        persistence.save(value: 99, for: .brightness, cameraID: "new")
        persistence.save(value: 42, for: .contrast, cameraID: "old")
        persistence.savePresets([source, extra], cameraID: "old")
        persistence.savePresets([target], cameraID: "new")

        persistence.migrateCameraData(from: "old", to: "new")
        persistence.migrateCameraData(from: "old", to: "new")

        XCTAssertEqual(persistence.load(for: .brightness, cameraID: "new"), 99)
        XCTAssertEqual(persistence.load(for: .contrast, cameraID: "new"), 42)
        let presets = persistence.loadPresets(cameraID: "new")
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets.first?.name, "Edited on target")
        XCTAssertEqual(presets.last?.id, extra.id)
    }

    func testMigrationDoesNotReplaceCorruptTargetPresets() {
        let invalid = Data("invalid-json".utf8)
        defaults.set(invalid, forKey: "presets.new")
        persistence.savePresets([CameraPreset(name: "Source", values: [:])], cameraID: "old")
        persistence.migrateCameraData(from: "old", to: "new")
        XCTAssertEqual(defaults.data(forKey: "presets.new"), invalid)
    }

    func testLastPhysicalIdentityIsClearedForCamerasWithoutSerialNumber() {
        persistence.saveLastSelectedCamera(id: "a", name: "Webcam", physicalID: "serial-a")
        XCTAssertEqual(persistence.loadLastSelectedCamera().physicalID, "serial-a")
        persistence.saveLastSelectedCamera(id: "b", name: "Webcam")
        XCTAssertNil(persistence.loadLastSelectedCamera().physicalID)
    }

}
