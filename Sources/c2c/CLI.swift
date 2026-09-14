import Foundation
import C2CCore
import Darwin

struct Arguments {
    var words: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    static let boolean: Set<String> = ["json", "no-fix", "force", "developer-mode", "clear-checkpoint", "help", "version"]
    static let valued: Set<String> = ["workspace", "port", "lines", "url", "title", "task", "iteration", "state", "mode", "project-url", "connector-name", "protocol-state", "waiting-for", "goal", "completed-subtasks", "known-issues", "next-step", "setup-mode", "changed-files", "tests", "exit-status", "notes", "command", "output", "output-file", "exit-code", "app", "debug-port"]
    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let item = raw[i]
            if item.hasPrefix("-") {
                let normalized = ["-w": "--workspace", "-h": "--help", "-v": "--version"][item] ?? item
                guard normalized.hasPrefix("--") else { throw C2CError("Unknown option: \(item)") }
                let pieces = normalized.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(pieces[0])
                if Self.boolean.contains(key) { guard pieces.count == 1 else { throw C2CError("Flag --\(key) takes no value") }; flags.insert(key) }
                else if Self.valued.contains(key) {
                    if pieces.count == 2 { options[key] = String(pieces[1]) }
                    else { i += 1; guard i < raw.count, !raw[i].hasPrefix("--") else { throw C2CError("Missing value for --\(key)") }; options[key] = raw[i] }
                } else { throw C2CError("Unknown option: \(item)") }
            } else { words.append(item) }
            i += 1
        }
    }
    func validate(command: String, subcommand: String) throws {
        let shared: Set<String> = ["workspace", "json"]
        let allowed: Set<String>
        switch command {
        case "serve": allowed = ["workspace", "port", "json"]
        case "entry": allowed = ["workspace", "json", "app", "debug-port"]
        case "start", "setup", "restart": allowed = shared.union(["port"])
        case "doctor": allowed = shared.union(["no-fix"])
        case "logs": allowed = shared.union(["lines"])
        case "session" where subcommand == "set": allowed = shared.union(["url", "title", "task", "iteration", "state", "mode", "project-url", "connector-name", "protocol-state", "waiting-for", "goal", "completed-subtasks", "known-issues", "next-step", "clear-checkpoint"])
        case "prefs" where subcommand == "set": allowed = ["json", "developer-mode", "setup-mode"]
        case "prefs", "sandbox-allow": allowed = ["json"]
        case "record": allowed = shared.union(["task", "iteration", "changed-files", "tests", "exit-status", "notes", "command", "output", "output-file", "exit-code"])
        case "update-check": allowed = ["json", "force"]
        default: allowed = shared
        }
        if let unknown = Set(options.keys).union(flags).subtracting(allowed).sorted().first { throw C2CError("Option --\(unknown) is not valid for \(command)") }
    }
    func integer(_ key: String, default fallback: Int? = nil, minimum: Int? = nil, maximum: Int? = nil) throws -> Int {
        guard let raw = options[key] else { if let fallback { return fallback }; throw C2CError("--\(key) is required") }
        guard raw.range(of: "^-?[0-9]+$", options: .regularExpression) != nil, let result = Int(raw), abs(Double(result)) <= 9007199254740991, minimum.map({ result >= $0 }) ?? true, maximum.map({ result <= $0 }) ?? true else { throw C2CError("Invalid integer for --\(key)") }
        return result
    }
    func require(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else { throw C2CError("--\(key) is required") }; return value
    }
}

@main struct CLI {
    static func defaultWorkspacePath() -> String {
        let current = FileManager.default.currentDirectoryPath
        // Swift Package schemes run executables from DerivedData by default.
        // In that case use the package containing this source file, so Xcode's
        // Run button selects the project the user opened instead of /Debug.
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

    static var configOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment["C2C_CODEX_CONFIG"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    static let help = """
    Codex with ChatGPT — Swift for macOS
    Usage: c2c [entry options]
           c2c <command> [options]

      (no command)               Inject into Codex/ChatGPT using this directory

      setup                       Start local bridge and one-time pairing
      start                       Start or reuse the local workspace bridge
      stop | restart              Manage the background bridge
      status | doctor [--no-fix]  Inspect or repair the connection
      pair | unpair              Create a pairing code or revoke authorization
      workspace                  Inspect the current workspace
      entry [--app PATH] [--debug-port N]
                                 Attach current workspace files over CDP
      logs [--lines N]            Show private bridge logs
      session get|set|clear       Remember ChatGPT project and conversation
      prefs get|set               Remember developer mode and setup preferences
      sandbox-allow              Add state directory to Codex writable_roots
      record                     Record execution evidence for MCP review
      update-check [--force]     Check this Swift checkout's configured upstream
      serve --workspace PATH     Run in foreground

    Shared options: -w/--workspace PATH, --json, -h/--help, -v/--version
    Session set: --url URL --project-url URL --mode project|long-chat --task ID
      --iteration N --state STATE --protocol-state STATE --waiting-for WHO
      --goal TEXT --completed-subtasks TEXT --known-issues TEXT --next-step TEXT
      --connector-name NAME --title TEXT --clear-checkpoint
    Record: --task ID --iteration N [--changed-files FILES|COUNT] [--tests TEXT]
      [--exit-status ok|failed|blocked] [--command TEXT --output-file PATH]
      [--output TEXT] [--exit-code N] [--notes TEXT]
    Prefs set: --developer-mode [--setup-mode auto|manual]
    Requires macOS 13+. No Node.js runtime.
    """
    static func emit(_ value: [String: Any], json: Bool, message: String? = nil) {
        if !json, let message { print(message); return }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: json ? [.sortedKeys] : [.sortedKeys, .prettyPrinted]) { print(String(decoding: data, as: UTF8.self)) }
    }
    static func main() async {
        do { try await run(Arguments(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            let json = CommandLine.arguments.contains("--json")
            emit(["ok": false, "error": error.localizedDescription], json: json, message: "✗ \(error.localizedDescription)")
            exit(1)
        }
    }
    static func run(_ args: Arguments) async throws {
        if args.flags.contains("version") { print(c2cVersion); return }
        if args.flags.contains("help") { print(help); return }
        // CDP injection is the primary, zero-configuration workflow. This also
        // makes Xcode's Run button useful without editing a Scheme first.
        let command = args.words.first ?? "entry"
        let sub = args.words.count > 1 ? args.words[1] : "get"
        guard args.words.count <= (["session", "prefs"].contains(command) ? 2 : 1) else { throw C2CError("Unexpected positional argument") }
        try args.validate(command: command, subcommand: sub)
        if ["serve", "start", "setup", "restart"].contains(command) {
            _ = try args.integer("port", default: 48765, minimum: 0, maximum: 65535)
        }
        let json = args.flags.contains("json")
        let state = AppPaths.stateDirectory
        if command == "sandbox-allow" { emit(try SandboxConfig.ensure(stateDirectory: state, configURL: configOverride), json: json); return }
        if command == "prefs" {
            if sub == "get" { emit(Preferences.get(stateDirectory: state), json: json) }
            else if sub == "set" { emit(try Preferences.set(options: args.options, flags: args.flags, stateDirectory: state), json: json) }
            else { throw C2CError("Unknown prefs command: \(sub)") }
            return
        }
        if command == "update-check" { try updateCheck(args, state: state); return }
        let root = args.options["workspace"] ?? defaultWorkspacePath()
        let workspace = try Workspace(root: root)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        switch command {
        case "serve":
            _ = try args.require("workspace")
            if ProcessInfo.processInfo.environment["C2C_DAEMON"] == "1" { _ = setsid() }
            signal(SIGPIPE, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let bridge = try Bridge(workspaceRoot: workspace.root, stateDirectory: state)
            try bridge.start(port: args.integer("port", default: 48765, minimum: 0, maximum: 65535))
            print("Bridge ready on http://127.0.0.1:\(bridge.port) (\(workspace.name))")
            fflush(stdout)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let lock = NSLock(); var finished = false
                var sources: [DispatchSourceSignal] = []
                let finish = {
                    lock.lock(); defer { lock.unlock() }
                    guard !finished else { return }; finished = true
                    bridge.stop(); sources.forEach { $0.cancel() }; sources.removeAll(); continuation.resume()
                }
                bridge.onShutdown = finish
                for sig in [SIGINT, SIGTERM] {
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                    source.setEventHandler(handler: finish); sources.append(source); source.resume()
                }
            }
            bridge.onShutdown = nil
        case "workspace":
            var info = workspace.info(); info["name"] = workspace.name; info["root"] = workspace.root; emit(info, json: json)
        case "entry":
            let appOverride = args.options["app"].map { ($0 as NSString).expandingTildeInPath }
            let preferredPort = try args.options["debug-port"].map { _ in try args.integer("debug-port", minimum: 1, maximum: 65535) }
            signal(SIGPIPE, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let service = EntryService(workspace: workspace, appOverride: appOverride.map { URL(fileURLWithPath: $0) }, preferredPort: preferredPort, log: { print($0); fflush(stdout) })
            let serviceTask = Task { try await service.run() }
            print("Workspace attachment entry running for \(workspace.name). Press Ctrl-C to stop.")
            fflush(stdout)
            let outcome: Result<Void, Error> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
                final class EntryShutdown: @unchecked Sendable {
                    private let lock = NSLock()
                    private var finished = false
                    var sources: [DispatchSourceSignal] = []
                    func finish(_ body: () -> Void) {
                        lock.lock(); defer { lock.unlock() }
                        guard !finished else { return }
                        finished = true
                        sources.forEach { $0.cancel() }
                        body()
                    }
                }
                let shutdown = EntryShutdown()
                for sig in [SIGINT, SIGTERM] {
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                    source.setEventHandler { service.stop(); serviceTask.cancel() }
                    shutdown.sources.append(source); source.resume()
                }
                Task {
                    do { try await serviceTask.value; shutdown.finish { continuation.resume(returning: .success(())) } }
                    catch { shutdown.finish { continuation.resume(returning: .failure(error)) } }
                }
            }
            try outcome.get()
        case "start", "setup", "restart":
            if command == "restart" { _ = try await Daemon.stop(workspaceID: workspace.id, stateDirectory: state) }
            var sandbox: [String: Any] = [:]
            if command == "setup" {
                do { sandbox = try SandboxConfig.ensure(stateDirectory: state, configURL: configOverride) }
                catch { sandbox = ["ok": false, "error": error.localizedDescription] }
            }
            let runtime = try await Daemon.ensure(workspace: workspace, stateDirectory: state, executable: executable, port: args.integer("port", default: 48765, minimum: 0, maximum: 65535))
            let mcpURL = "http://127.0.0.1:\(runtime["port"]!)/mcp"
            var result: [String: Any] = ["ok": true, "workspaceId": workspace.id, "workspaceName": workspace.name, "port": runtime["port"]!, "mcpUrl": mcpURL, "local": true]
            if command == "setup" {
                let pairing = try await Daemon.admin(runtime, route: "/admin/pairing", method: "POST")
                result["pairingCode"] = pairing["code"]; result["pairingExpiresAt"] = pairing["expiresAt"]; result["sandbox"] = sandbox
            }
            emit(result, json: json)
        case "stop": emit(["ok": true, "stopped": try await Daemon.stop(workspaceID: workspace.id, stateDirectory: state)], json: json)
        case "status":
            let observed = await Daemon.observation(workspaceID: workspace.id, stateDirectory: state)
            if observed.state == "healthy", let runtime = observed.runtime {
                var info = try await Daemon.admin(runtime, route: "/admin/info"); info["ok"] = true; info["running"] = true; emit(info, json: json)
            } else { emit(["ok": false, "running": observed.state == "unknown" ? NSNull() : false, "state": observed.state, "reason": observed.reason], json: json) }
        case "pair":
            let runtime = try await Daemon.ensure(workspace: workspace, stateDirectory: state, executable: executable)
            let pairing = try await Daemon.admin(runtime, route: "/admin/pairing", method: "POST")
            emit(["ok": true, "code": pairing["code"]!, "expiresAt": pairing["expiresAt"]!, "pairingCode": pairing["code"]!, "pairingExpiresAt": pairing["expiresAt"]!], json: json)
        case "unpair":
            let observed = await Daemon.observation(workspaceID: workspace.id, stateDirectory: state)
            if observed.state == "healthy", let runtime = observed.runtime { emit(try await Daemon.admin(runtime, route: "/admin/revoke-all", method: "POST"), json: json) }
            else if observed.state == "stopped" { let auth = try AuthService(workspaceID: workspace.id, workspaceName: workspace.name, stateDirectory: state); emit(["revoked": try auth.revokeAll()], json: json) }
            else { throw C2CError("Bridge state is unknown; cannot safely revoke offline") }
        case "logs":
            let lines = try args.integer("lines", default: 50, minimum: 1, maximum: 10000)
            let file = state.appendingPathComponent("logs/bridge-\(workspace.id).out.log")
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let length = try handle.seekToEnd(); try handle.seek(toOffset: length > 1024 * 1024 ? length - 1024 * 1024 : 0)
                let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self).components(separatedBy: "\n").suffix(lines).joined(separator: "\n")
                if json { emit(["ok": true, "logs": text], json: true) } else { print(text) }
            } else { emit(["ok": true, "logs": ""], json: json, message: "No bridge logs yet.") }
        case "session":
            let store = SessionStore(workspaceID: workspace.id, stateDirectory: state)
            switch sub {
            case "get": emit(["ok": true, "session": store.get() as Any? ?? NSNull(), "conversation": store.conversation()], json: json)
            case "set": emit(try store.set(args.options, flags: args.flags), json: json)
            case "clear": emit(try store.clear(), json: json)
            default: throw C2CError("Unknown session command: \(sub)")
            }
        case "record":
            var values: [String: Any] = ["taskId": try args.require("task"), "iteration": try args.integer("iteration", minimum: 0), "exitStatus": args.options["exit-status"] ?? "ok"]
            guard ["ok", "failed", "blocked"].contains(values["exitStatus"] as! String) else { throw C2CError("exit-status must be ok, failed or blocked") }
            let changed = args.options["changed-files"] ?? "0"
            if changed.range(of: "^-?[0-9]+$", options: .regularExpression) != nil {
                guard let count = Int(changed), count >= 0, Double(count) <= 9007199254740991 else { throw C2CError("changed-files must be non-negative") }; values["changedFiles"] = count
            } else { values["changedFiles"] = changed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            for key in ["tests", "notes", "command", "output"] { values[key] = args.options[key] }
            if args.options["exit-code"] != nil { values["exitCode"] = try args.integer("exit-code") }
            if let file = args.options["output-file"] { let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file)); defer { try? handle.close() }; values["output"] = String(decoding: try handle.read(upToCount: 256 * 1024) ?? Data(), as: UTF8.self) }
            emit(try ExecutionStore(workspaceID: workspace.id, stateDirectory: state).record(values), json: json)
        case "doctor": try await doctor(args, workspace: workspace, state: state, executable: executable)
        default: throw C2CError("Unknown command: \(command). Run c2c --help")
        }
    }
    static func doctor(_ args: Arguments, workspace: Workspace, state: URL, executable: String) async throws {
        let fix = !args.flags.contains("no-fix")
        var report: [String: [String: Any]] = ["platform": ["ok": true, "detail": "Swift native / macOS"], "workspace": ["ok": true, "detail": workspace.name], "git": ["ok": findExecutable("git") != nil]]
        var repairs: [String] = []
        if fix {
            do { let result = try SandboxConfig.ensure(stateDirectory: state, configURL: configOverride); report["sandbox"] = ["ok": true]; if result["added"] as? Bool == true { repairs.append("Added state directory to Codex sandbox") } }
            catch { report["sandbox"] = ["ok": false, "detail": error.localizedDescription] }
        } else { report["sandbox"] = ["ok": SandboxConfig.isAllowed(stateDirectory: state, configURL: configOverride)] }
        let observed = await Daemon.observation(workspaceID: workspace.id, stateDirectory: state)
        var runtime = observed.state == "healthy" ? observed.runtime : nil
        if runtime == nil, fix, observed.state == "stopped" {
            do { runtime = try await Daemon.ensure(workspace: workspace, stateDirectory: state, executable: executable); repairs.append("Started bridge") }
            catch { report["bridge"] = ["ok": false, "detail": error.localizedDescription] }
        }
        report["bridge"] = report["bridge"] ?? ["ok": runtime != nil, "detail": observed.state == "unknown" ? "Unknown bridge identity; no automatic changes" : (runtime == nil ? "stopped" : "running")]
        if let runtime {
            let (status, _) = try await Daemon.request(port: runtime["port"] as! Int, route: "/mcp", method: "POST")
            report["mcp"] = ["ok": status == 401, "detail": "Unauthenticated request: \(status)"]
            report["oauth"] = ["ok": status == 401]
        }
        emit(["ok": report.values.allSatisfy { $0["ok"] as? Bool == true }, "report": report, "repairs": repairs], json: args.flags.contains("json"))
    }
    static func updateCheck(_ args: Arguments, state: URL) throws {
        // Never point Swift installations at the TypeScript upstream or overwrite a native build.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) { directory.deleteLastPathComponent() }
        let json = args.flags.contains("json")
        guard directory.path != "/", let git = findExecutable("git") else { emit(["ok": true, "checked": false, "updateAvailable": false, "note": "No Swift source checkout; rebuild from your configured Swift repository."], json: json); return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = formatter.string(from: Date())
        let cache = state.appendingPathComponent("update-check.json")
        if !args.flags.contains("force"), let saved = AppPaths.readJSON(cache), saved["date"] as? String == today, saved["checkout"] as? String == directory.path {
            emit(["ok": true, "version": c2cVersion, "checked": false, "updateAvailable": saved["updateAvailable"] as? Bool ?? false, "note": "Already checked today"], json: json); return
        }
        let local = try runCommand(git, ["rev-parse", "HEAD"], directory: directory, timeout: 8)
        guard local.code == 0 else { emit(["ok": true, "checked": false, "updateAvailable": false, "note": "No git checkout configured"], json: json); return }
        let remote = try runCommand(git, ["ls-remote", "origin", "HEAD"], directory: directory, timeout: 8)
        let commit = remote.output.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        let checked = remote.code == 0 && commit != nil
        let available = checked && local.output.trimmingCharacters(in: .whitespacesAndNewlines) != commit
        if checked { try AppPaths.writeJSON(["date": today, "checkout": directory.path, "updateAvailable": available, "remoteCommit": commit!], to: cache) }
        emit(["ok": true, "version": c2cVersion, "checked": checked, "updateAvailable": available, "note": checked ? "Checked configured Swift upstream" : "No reachable upstream configured"], json: json)
    }
}
