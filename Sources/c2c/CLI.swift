import C2CCore
import Darwin
import Foundation

struct Arguments {
    var command: String?
    var workspace: String?
    var app: String?
    var debugPort: Int?
    var help = false
    var version = false

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            switch argument {
            case "-h", "--help":
                help = true
            case "-v", "--version":
                version = true
            case "-w", "--workspace", "--app", "--debug-port":
                index += 1
                guard index < raw.count else { throw C2CError("Missing value for \(argument)") }
                try assign(argument, value: raw[index])
            default:
                if argument.hasPrefix("--workspace=") {
                    workspace = String(argument.dropFirst("--workspace=".count))
                } else if argument.hasPrefix("--app=") {
                    app = String(argument.dropFirst("--app=".count))
                } else if argument.hasPrefix("--debug-port=") {
                    try setDebugPort(String(argument.dropFirst("--debug-port=".count)))
                } else if argument.hasPrefix("-") {
                    throw C2CError("Unknown option: \(argument)")
                } else if command == nil {
                    command = argument
                } else {
                    throw C2CError("Unexpected positional argument: \(argument)")
                }
            }
            index += 1
        }

        if let command, command != "entry" {
            throw C2CError("Unknown command: \(command). Run c2c --help")
        }
        if workspace?.isEmpty == true { throw C2CError("--workspace cannot be empty") }
        if app?.isEmpty == true { throw C2CError("--app cannot be empty") }
    }

    private mutating func assign(_ option: String, value: String) throws {
        switch option {
        case "-w", "--workspace": workspace = value
        case "--app": app = value
        case "--debug-port": try setDebugPort(value)
        default: break
        }
    }

    private mutating func setDebugPort(_ value: String) throws {
        guard let port = Int(value), (1...65_535).contains(port) else {
            throw C2CError("Invalid debug port: \(value)")
        }
        debugPort = port
    }
}

@main
struct CLI {
    static let help = """
    Codex with ChatGPT — Swift for macOS
    Usage: c2c [entry] [options]

      (no command)               Attach the current directory over CDP
      entry                      Attach a workspace over CDP

    Options:
      -w, --workspace PATH       Workspace to expose as safe file attachments
          --app PATH             Codex or ChatGPT application path
          --debug-port PORT      Existing CDP debug port
      -h, --help                 Show this help
      -v, --version              Show the version

    Requires macOS 13+. No Node.js, MCP server, OAuth, tunnel, or public listener.
    """

    static func defaultWorkspacePath() -> String {
        let current = FileManager.default.currentDirectoryPath
        // Swift Package schemes run executables from DerivedData by default.
        // In that case use the package containing this source file.
        guard current.contains("/Library/Developer/Xcode/DerivedData/") else { return current }
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("Package.swift").path) else {
            return current
        }
        return package.path
    }

    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.help { print(help); return }
            if arguments.version { print(c2cVersion); return }
            try await run(arguments)
        } catch {
            fputs("✗ \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ arguments: Arguments) async throws {
        let root = arguments.workspace ?? defaultWorkspacePath()
        let workspace = try Workspace(root: root)
        let appOverride = arguments.app.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }

        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let service = EntryService(
            workspace: workspace,
            appOverride: appOverride,
            preferredPort: arguments.debugPort,
            log: { print($0); fflush(stdout) }
        )
        let serviceTask = Task { try await service.run() }
        print("Workspace attachment entry running for \(workspace.name). Press Ctrl-C to stop.")
        fflush(stdout)

        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            final class EntryShutdown: @unchecked Sendable {
                private let lock = NSLock()
                private var finished = false
                var sources: [DispatchSourceSignal] = []

                func finish(_ body: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !finished else { return }
                    finished = true
                    sources.forEach { $0.cancel() }
                    body()
                }
            }

            let shutdown = EntryShutdown()
            for signalNumber in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler {
                    service.stop()
                    serviceTask.cancel()
                }
                shutdown.sources.append(source)
                source.resume()
            }
            Task {
                do {
                    try await serviceTask.value
                    shutdown.finish { continuation.resume(returning: .success(())) }
                } catch {
                    shutdown.finish { continuation.resume(returning: .failure(error)) }
                }
            }
        }
        try outcome.get()
    }
}
