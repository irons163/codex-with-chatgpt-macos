import Foundation
import XCTest
@testable import C2CCore

final class PreferencesTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2c-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDirectory {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        stateDirectory = nil
        try super.tearDownWithError()
    }

    func testDefaultsAreUnremembered() {
        let prefs = Preferences.get(stateDirectory: stateDirectory)
        XCTAssertEqual(prefs["developerModeEnabled"] as? Bool, false)
        XCTAssertTrue(prefs["setupMode"] is NSNull)
        XCTAssertEqual((prefs["remembered"] as? [String: Any])?["developerMode"] as? Bool, false)
        XCTAssertEqual((prefs["remembered"] as? [String: Any])?["setupMode"] as? Bool, false)
        XCTAssertTrue((prefs["setupChoicePrompt"] as? String)?.contains("回复「1」或「2」") == true)
    }

    func testSetPersistsDeveloperModeAndSetupChoice() throws {
        let first = try Preferences.set(
            options: ["setup-mode": " AUTO "],
            flags: ["developer-mode"],
            stateDirectory: stateDirectory
        )
        XCTAssertEqual(first["developerModeEnabled"] as? Bool, true)
        XCTAssertEqual(first["setupMode"] as? String, "auto")
        XCTAssertEqual((first["remembered"] as? [String: Any])?["developerMode"] as? Bool, true)
        XCTAssertEqual((first["remembered"] as? [String: Any])?["setupMode"] as? Bool, true)

        let second = try Preferences.set(
            options: ["setup-mode": "manual"],
            flags: [],
            stateDirectory: stateDirectory
        )
        XCTAssertEqual(second["developerModeEnabled"] as? Bool, true)
        XCTAssertEqual(second["setupMode"] as? String, "manual")

        let stored = try XCTUnwrap(AppPaths.readJSON(stateDirectory.appendingPathComponent("prefs.json")))
        XCTAssertEqual(stored["developerModeEnabled"] as? Bool, true)
        XCTAssertEqual(stored["setupMode"] as? String, "manual")
        XCTAssertNotNil(stored["updatedAt"] as? String)
    }

    func testSetRejectsInvalidOrEmptyChanges() {
        XCTAssertThrowsError(
            try Preferences.set(options: ["setup-mode": "sometimes"], flags: [], stateDirectory: stateDirectory)
        )
        XCTAssertThrowsError(
            try Preferences.set(options: [:], flags: [], stateDirectory: stateDirectory)
        )
        XCTAssertThrowsError(
            try Preferences.set(options: ["other": "x"], flags: [], stateDirectory: stateDirectory)
        )
        XCTAssertThrowsError(
            try Preferences.set(options: [:], flags: ["other"], stateDirectory: stateDirectory)
        )
    }

    func testMalformedStoredValuesFallBackToSafeDefaults() throws {
        try AppPaths.writeJSON(
            [
                "developerModeEnabled": 1,
                "setupMode": "invalid",
                "updatedAt": 123,
            ],
            to: stateDirectory.appendingPathComponent("prefs.json")
        )

        let prefs = Preferences.get(stateDirectory: stateDirectory)
        XCTAssertEqual(prefs["developerModeEnabled"] as? Bool, false)
        XCTAssertTrue(prefs["setupMode"] is NSNull)
    }
}
