import XCTest
@testable import C2CCore

final class TunnelTests: XCTestCase {
    func testQuickTunnelStartReuseAndStopWithSplitOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try AppPaths.ensureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("fake-cloudflared")
        try """
        #!/bin/sh
        printf 'https://test-bridge.' >&2
        sleep 0.1
        printf 'trycloudflare.com\\n' >&2
        exec sleep 20
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let tunnel = TunnelManager(workspaceID: "test", stateDirectory: root, binary: fake.path, startTimeout: 3)
        defer { tunnel.stop() }
        XCTAssertEqual(try tunnel.start(port: 1234), "https://test-bridge.trycloudflare.com")
        XCTAssertEqual(try tunnel.start(port: 1234), "https://test-bridge.trycloudflare.com")
        XCTAssertEqual(tunnel.status()["running"] as? Bool, true)
        tunnel.stop(); XCTAssertNil(tunnel.publicURL); XCTAssertEqual(tunnel.status()["running"] as? Bool, false)
    }
    func testFailedChildDoesNotLeavePhantomTunnel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try AppPaths.ensureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let tunnel = TunnelManager(workspaceID: "test", stateDirectory: root, binary: "/usr/bin/false", startTimeout: 1)
        XCTAssertThrowsError(try tunnel.start(port: 1234)); XCTAssertNil(tunnel.publicURL)
    }
    func testHostnameValidation() throws {
        XCTAssertEqual(try TunnelManager.hostname("C2C.EXAMPLE.COM."), "c2c.example.com")
        XCTAssertThrowsError(try TunnelManager.hostname("example.com;rm -rf /"))
        XCTAssertThrowsError(try TunnelManager.hostname("-bad.example.com"))
        XCTAssertThrowsError(try TunnelManager.hostname("https://example.com/path"))
        XCTAssertEqual(try TunnelManager.zone("https://EXAMPLE.com/path"), "example.com")
    }
}
