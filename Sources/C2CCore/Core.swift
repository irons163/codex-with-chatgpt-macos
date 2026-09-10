import Foundation
import Security
import Darwin

public let c2cVersion = "0.1.1-swift.1"
public let c2cService = "c2c-bridge"
public struct C2CError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum AppPaths {
    public static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["C2C_STATE_DIR"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/codex-with-chatgpt-macos", isDirectory: true)
    }
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    public static func writeJSON(_ value: Any, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        // Create privately before atomic replacement; never briefly expose credentials via umask.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw C2CError("Cannot create private state file") }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temp) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard count > 0 else { throw C2CError("Cannot write state file") }
                written += count
            }
        }
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw C2CError("Cannot persist state file") }
    }
    public static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
public func secureToken(prefix: String = "", bytes: Int = 32) -> String {
    var data = [UInt8](repeating: 0, count: bytes)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes, &data) == errSecSuccess, "System random unavailable")
    return prefix + Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
public func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
public func findExecutable(_ name: String) -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
}
public struct CommandResult { public let code: Int32; public let output: String }
public func runCommand(_ executable: String, _ arguments: [String], directory: URL? = nil, timeout: TimeInterval = 45) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
    let lock = NSLock()
    var collected = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        lock.lock(); if collected.count < 2 * 1024 * 1024 { collected.append(data.prefix(2 * 1024 * 1024 - collected.count)) }; lock.unlock()
    }
    defer { pipe.fileHandleForReading.readabilityHandler = nil }
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw C2CError("Command timed out: \(URL(fileURLWithPath: executable).lastPathComponent)")
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    lock.lock(); collected.append(tail.prefix(max(0, 2 * 1024 * 1024 - collected.count))); let output = String(decoding: collected, as: UTF8.self); lock.unlock()
    return CommandResult(code: process.terminationStatus, output: output)
}
