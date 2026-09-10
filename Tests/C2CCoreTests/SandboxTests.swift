import Foundation
import XCTest
@testable import C2CCore

final class SandboxTests: XCTestCase {
    private var root: URL!
    private var stateDirectory: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2c-sandbox-\(UUID().uuidString)", isDirectory: true)
        stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        configURL = root.appendingPathComponent("codex/config.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        stateDirectory = nil
        configURL = nil
        try super.tearDownWithError()
    }

    func testEnsureAddsTableToEmptyConfigAndIsIdempotent() throws {
        let first = try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)
        XCTAssertEqual(first["added"] as? Bool, true)
        XCTAssertEqual(first["alreadyAllowed"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertTrue(content.contains("[sandbox_workspace_write]"))
        XCTAssertTrue(content.contains("writable_roots = [\"\(stateDirectory.path)\"]"))
        XCTAssertTrue(SandboxConfig.isAllowed(stateDirectory: stateDirectory, configURL: configURL))

        let second = try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)
        XCTAssertEqual(second["added"] as? Bool, false)
        XCTAssertEqual(second["alreadyAllowed"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), content)
    }

    func testExistingConfigAndMultilineArrayArePreserved() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let otherState = root.appendingPathComponent("other", isDirectory: true)
        let original = """
        [general]
        color = "blue"

        [sandbox_workspace_write]
        writable_roots = [
          "\(otherState.path)",
        ]

        [network]
        enabled = true
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        _ = try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("color = \"blue\""))
        XCTAssertTrue(content.contains("enabled = true"))
        XCTAssertTrue(content.contains("\"\(otherState.path)\""))
        XCTAssertTrue(content.contains("\"\(stateDirectory.path)\""))
        XCTAssertTrue(SandboxConfig.isAllowed(stateDirectory: stateDirectory, configURL: configURL))
    }

    func testSingleLineArrayAndSingleQuotedPathsAreRecognized() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = "[sandbox_workspace_write]\nwritable_roots = ['\(stateDirectory.path)']\n"
        try content.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(SandboxConfig.isAllowed(stateDirectory: stateDirectory, configURL: configURL))
        let result = try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)
        XCTAssertEqual(result["added"] as? Bool, false)
        XCTAssertEqual(result["alreadyAllowed"] as? Bool, true)
        XCTAssertEqual(result["ok"] as? Bool, true)
    }

    func testMissingTableIsInsertedAfterExistingContent() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[general]\ncolor = \"blue\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        _ = try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("[general]\ncolor = \"blue\"\n\n[sandbox_workspace_write]"))
    }

    func testCommentsAndBracketHashPathsAreParsedWithoutDuplicateKeys() throws {
        stateDirectory = root.appendingPathComponent("state]#hash", isDirectory: true)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        [sandbox_workspace_write] # keep this comment
        writable_roots = ["/already]#root"] # and this one
        [general]
        color = "blue"
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let result = try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["added"] as? Bool, true)
        XCTAssertTrue(SandboxConfig.isAllowed(stateDirectory: stateDirectory, configURL: configURL))
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "writable_roots").count - 1, 1)
        XCTAssertTrue(content.contains("state]#hash"))
        XCTAssertTrue(content.contains("[sandbox_workspace_write] # keep this comment"))
        XCTAssertTrue(content.contains("[general]"))
    }

    func testMalformedWritableRootsFailsExplicitlyInsteadOfAddingDuplicateKey() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        [sandbox_workspace_write] # table comment
        writable_roots = ["/broken] # the bracket is inside the string
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SandboxConfig.ensure(stateDirectory: stateDirectory, configURL: configURL)) { error in
            XCTAssertTrue(error is SandboxConfigError)
            XCTAssertNotNil((error as? SandboxConfigError)?.errorDescription)
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }
}
