import Foundation
import XCTest
@testable import CodexWithChatGPTApp

final class AppUpdateTests: XCTestCase {
    func testFeedsArePinnedToThisRepositoryAndArchitecture() {
        #if arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "arm64"
        #endif

        XCTAssertEqual(UpdateChannel.stable.feedName, "appcast-\(architecture).xml")
        XCTAssertEqual(UpdateChannel.beta.feedName, "appcast-beta-\(architecture).xml")
        XCTAssertEqual(
            AppUpdateConfiguration.feedURL(channel: .stable).absoluteString,
            "https://github.com/irons163/codex-with-chatgpt-macos/releases/latest/download/appcast-\(architecture).xml"
        )
    }

    func testSourceInfoPlistDoesNotContainAProductionKeyOrInsecureOverride() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Packaging/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertNil(plist["SUPublicEDKey"])
        XCTAssertNil(plist["SUAllowsInsecureUpdates"])
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "13.0")
    }
}
