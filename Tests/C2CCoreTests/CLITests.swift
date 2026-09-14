import XCTest
@testable import C2CCore

final class CLITests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var state: URL!
    private var config: URL!
    private var executable: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("project with spaces"); state = root.appendingPathComponent("state"); config = root.appendingPathComponent("config.toml")
        try AppPaths.ensureDirectory(project)
        try "// swift-tools-version: 5.9\n".write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        executable = checkout.appendingPathComponent(".build/debug/c2c")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build the c2c executable before CLI integration tests") }
    }
    override func tearDownWithError() throws {
        _ = try? run(["stop", "--workspace", project.path, "--json"])
        try? FileManager.default.removeItem(at: root)
    }
    private func run(_ args: [String], expected: Int32 = 0) throws -> [String: Any] {
        let process = Process(); process.executableURL = executable; process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["C2C_STATE_DIR"] = state.path; environment["C2C_CODEX_CONFIG"] = config.path
        process.environment = environment; process.currentDirectoryURL = project
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw C2CError("CLI timed out: \(args)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, expected, String(decoding: data, as: UTF8.self))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func testLocalSetupReusesDaemonAndStopsCleanly() throws {
        let options = ["--workspace", project.path, "--json"]
        let started = try run(["setup", "--port", "0"] + options)
        XCTAssertEqual(started["ok"] as? Bool, true)
        XCTAssertEqual(started["local"] as? Bool, true)
        XCTAssertNotNil(started["pairingCode"] as? String)
        let sandbox = try XCTUnwrap(started["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["configPath"] as? String, config.path)
        XCTAssertTrue(try String(contentsOf: config).contains("writable_roots"))
        let status = try run(["status"] + options)
        XCTAssertEqual(status["running"] as? Bool, true)
        let pid = try XCTUnwrap(status["pid"] as? Int)
        let again = try run(["start"] + options)
        XCTAssertEqual(again["port"] as? Int, started["port"] as? Int)
        let next = try run(["status"] + options)
        XCTAssertEqual(next["pid"] as? Int, pid)
        let doctor = try run(["doctor", "--no-fix"] + options)
        XCTAssertEqual(doctor["ok"] as? Bool, true)
        let stopped = try run(["stop"] + options)
        XCTAssertEqual(stopped["stopped"] as? Bool, true)
        XCTAssertEqual(try run(["status"] + options)["running"] as? Bool, false)
    }
    func testSessionPreferencesAndExecutionRecordCLI() throws {
        _ = try run(["prefs", "set", "--setup-mode", "manual", "--developer-mode", "--json"])
        XCTAssertEqual(try run(["prefs", "get", "--json"])["setupMode"] as? String, "manual")
        _ = try run(["session", "set", "--mode", "project", "--project-url", "https://chatgpt.com/g/g-p-example/project", "--json"])
        let session = try run(["session", "get", "--json"])
        XCTAssertEqual((session["conversation"] as? [String: Any])?["mode"] as? String, "project")
        let record = try run(["record", "--task", "task-1", "--iteration", "2", "--changed-files", "Sources/a.swift,Tests/a.swift", "--tests", "passed", "--command", "swift test", "--output", "tests passed", "--exit-code", "0", "--json"])
        XCTAssertEqual(record["outputAvailable"] as? Bool, true)
        let ws = try Workspace(root: project.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("executions/\(ws.id).jsonl").path))
    }
    func testInvalidArgumentsFailBeforeStartingDaemon() throws {
        for arguments in [
            ["start", "--port", "70000"],
            ["start", "--tunnel"],
            ["setup", "--no-tunnel"],
            ["start", "--setup-mode", "manual"],
            ["record", "--task", "t", "--iteration", "1.2"],
            ["record", "--task", "t", "--iteration", "0", "--changed-files", "-3"],
            ["session", "set", "--iteration", "-1"],
            ["prefs", "set", "--setup-mode", "invalid"]
        ] {
            let result = try run(arguments + ["--json"], expected: 1)
            XCTAssertEqual(result["ok"] as? Bool, false)
        }
        XCTAssertEqual(try run(["status", "--json"])["running"] as? Bool, false)
    }
}
