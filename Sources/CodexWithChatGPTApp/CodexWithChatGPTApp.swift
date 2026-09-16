import AppKit
import C2CCore
import Sparkle
import SwiftUI

enum UpdateChannel {
    case stable
    case beta

    var feedName: String {
        let prefix = self == .stable ? "appcast" : "appcast-beta"
        #if arch(x86_64)
        return "\(prefix)-x86_64.xml"
        #else
        return "\(prefix)-arm64.xml"
        #endif
    }
}

enum AppUpdateConfiguration {
    static let repository = "irons163/codex-with-chatgpt-macos"

    static func feedURL(channel: UpdateChannel) -> URL {
        URL(
            string: "https://github.com/\(repository)/releases/latest/download/\(channel.feedName)"
        )!
    }
}

@MainActor
private final class UpdateController: NSObject, ObservableObject {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    override init() {
        super.init()
        if isPackagedApp {
            updaterController.updater.automaticallyChecksForUpdates = true
        }
    }

    var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func checkForUpdates() {
        if isPackagedApp {
            updaterController.checkForUpdates(nil)
        } else if let url = URL(string: "https://github.com/\(AppUpdateConfiguration.repository)/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdateConfiguration.feedURL(channel: .stable).absoluteString
    }
}

@MainActor
private final class InjectionModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var language = AppLanguage.english
    @Published private(set) var statusKey = AppTextKey.starting
    @Published private(set) var statusReplacements: [String: String] = [:]

    private var entryProcess: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var runID = UUID()

    var status: String {
        AppLocalization.text(statusKey, language: language, replacements: statusReplacements)
    }

    func text(_ key: AppTextKey) -> String {
        AppLocalization.text(key, language: language)
    }

    init() {
        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    func start() {
        stop(updateStatus: false)
        do {
            let workspace = try runtimeWorkspace()
            let id = UUID()
            runID = id
            let helper = try helperExecutable()
            let process = Process()
            let pipe = Pipe()
            process.executableURL = helper
            process.arguments = ["entry", "--workspace", workspace.root]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                Task { @MainActor in
                    guard self?.runID == id else { return }
                    self?.consumeOutput(String(decoding: data, as: UTF8.self))
                }
            }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard self?.runID == id else { return }
                    self?.entryProcess = nil
                    self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self?.outputPipe = nil
                    self?.isRunning = false
                    self?.setStatus(
                        process.terminationStatus == 0 ? .stopped : .processFailed,
                        replacements: ["code": String(process.terminationStatus)]
                    )
                }
            }
            try process.run()
            entryProcess = process
            outputPipe = pipe
            isRunning = true
            setStatus(.injecting)
        } catch {
            isRunning = false
            setStatus(.startFailed, replacements: ["error": error.localizedDescription])
        }
    }

    private func consumeOutput(_ chunk: String) {
        outputBuffer += chunk
        let lines = outputBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        outputBuffer = String(lines.last ?? "")
        for line in lines.dropLast() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix(EntryService.localeEventPrefix) else { continue }
            let identifier = String(value.dropFirst(EntryService.localeEventPrefix.count))
            language = AppLanguage.matchingCodexIdentifier(identifier)
            setStatus(.injected)
        }
    }

    private func setStatus(_ key: AppTextKey, replacements: [String: String] = [:]) {
        statusKey = key
        statusReplacements = replacements
    }

    func stop() {
        stop(updateStatus: true)
    }

    private func stop(updateStatus: Bool) {
        runID = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        outputBuffer = ""
        if let entryProcess, entryProcess.isRunning {
            entryProcess.terminate()
        }
        entryProcess = nil
        isRunning = false
        if updateStatus { setStatus(.stopped) }
    }

    private func runtimeWorkspace() throws -> Workspace {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("codex-with-chatgpt-macos", isDirectory: true)
            .appendingPathComponent("runtime-workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return try Workspace(root: root.path)
    }

    private func helperExecutable() throws -> URL {
        let packaged = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/c2c")
        if FileManager.default.isExecutableFile(atPath: packaged.path) {
            return packaged
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("c2c")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        throw C2CError(AppLocalization.text(.helperMissing, language: language))
    }
}

@main
private struct CodexWithChatGPTApp: App {
    @StateObject private var injection = InjectionModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        MenuBarExtra("Codex with ChatGPT", systemImage: "folder.badge.gearshape") {
            Text(injection.status)
            Divider()
            Button(injection.text(injection.isRunning ? .reinject : .startInjection)) {
                injection.start()
            }
            Button(injection.text(.checkUpdates)) {
                updates.checkForUpdates()
            }
            Divider()
            Button(injection.text(.quit)) {
                injection.stop()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
