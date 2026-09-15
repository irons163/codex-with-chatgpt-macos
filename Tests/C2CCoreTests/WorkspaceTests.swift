import CryptoKit
import XCTest
@testable import C2CCore

final class WorkspaceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2c-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    func testWorkspaceUsesCanonicalRootAndStableIdentity() throws {
        let root = try temporaryDirectory()
        let workspace = try Workspace(root: root.path)
        let canonical = root.resolvingSymlinksInPath().path
        let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) == true
        let identitySource = caseSensitive ? canonical : canonical.lowercased()
        let expected = SHA256.hash(data: Data(identitySource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)

        XCTAssertEqual(workspace.root, canonical)
        XCTAssertEqual(workspace.name, root.lastPathComponent)
        XCTAssertEqual(workspace.id, String(expected))
    }

    func testWorkspaceRejectsMissingOrNonDirectoryRoots() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("file.txt")
        try "text".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Workspace(root: root.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try Workspace(root: file.path))
    }
}
