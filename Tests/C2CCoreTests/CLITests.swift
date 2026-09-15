import XCTest
@testable import C2CCore

final class CLITests: XCTestCase {
    private var executable: URL!

    override func setUpWithError() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        executable = checkout.appendingPathComponent(".build/debug/c2c")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build the c2c executable before CLI integration tests")
        }
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    func testHelpAndVersionDescribeOnlyCDPEntryWorkflow() throws {
        let help = try run(["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.output.contains("Usage: c2c [entry] [options]"))
        XCTAssertTrue(help.output.contains("No Node.js, MCP server, OAuth, tunnel, or public listener"))
        XCTAssertFalse(help.output.contains("setup                       Start"))

        let version = try run(["--version"])
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.output.trimmingCharacters(in: .whitespacesAndNewlines), c2cVersion)
    }

    func testRemovedCommandsAndLegacyOptionsAreRejected() throws {
        for arguments in [
            ["setup"],
            ["start"],
            ["serve"],
            ["session", "get"],
            ["record"],
            ["--json"],
            ["entry", "--debug-port", "0"],
            ["entry", "--debug-port", "70000"]
        ] {
            let result = try run(arguments)
            XCTAssertNotEqual(result.status, 0, arguments.joined(separator: " "))
        }
    }
}
