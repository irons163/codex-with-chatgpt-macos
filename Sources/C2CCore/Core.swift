import Foundation
import Darwin

public let c2cVersion = "0.1.1-swift.1"
public struct C2CError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
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
