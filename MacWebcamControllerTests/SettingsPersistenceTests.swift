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
}
