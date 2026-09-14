import AppKit
import C2CCore
import Sparkle
import SwiftUI

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }

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
    private static let channelDefaultsKey = "c2c.update-channel"

    @Published var channel: UpdateChannel {
        didSet {
            UserDefaults.standard.set(channel.rawValue, forKey: Self.channelDefaultsKey)
            updaterController.updater.resetUpdateCycle()
        }
    }

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    override init() {
        channel = UpdateChannel(
            rawValue: UserDefaults.standard.string(forKey: Self.channelDefaultsKey) ?? ""
        ) ?? .stable
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
        AppUpdateConfiguration.feedURL(channel: channel).absoluteString
    }
}

@MainActor
private final class WorkspaceEntryModel: ObservableObject {
    private static let workspaceDefaultsKey = "c2c.workspace-path"

    @Published var workspacePath: String
    @Published private(set) var isRunning = false
    @Published private(set) var status = "選擇工作目錄後啟動"

    private var entryProcess: Process?
    private var outputPipe: Pipe?
    private var runID = UUID()

    init() {
        let remembered = UserDefaults.standard.string(forKey: Self.workspaceDefaultsKey) ?? ""
        workspacePath = FileManager.default.fileExists(atPath: remembered) ? remembered : ""
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "選擇要讓 ChatGPT 讀取的工作目錄"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !workspacePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        workspacePath = selected.standardizedFileURL.path
        UserDefaults.standard.set(workspacePath, forKey: Self.workspaceDefaultsKey)
        start()
    }

    func start() {
        guard !workspacePath.isEmpty else {
            chooseWorkspace()
            return
        }
        stop(updateStatus: false)
        do {
            let workspace = try Workspace(root: workspacePath)
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
                let lines = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \Character.isNewline)
                guard let last = lines.last else { return }
                Task { @MainActor in
                    guard self?.runID == id else { return }
                    self?.status = String(last)
                }
            }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard self?.runID == id else { return }
                    self?.entryProcess = nil
                    self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self?.outputPipe = nil
                    self?.isRunning = false
                    self?.status = process.terminationStatus == 0
                        ? "已停止"
                        : "執行失敗（exit \(process.terminationStatus)）"
                }
            }
            try process.run()
            entryProcess = process
            outputPipe = pipe
            isRunning = true
            status = "正在連接 \(workspace.name)…"
        } catch {
            isRunning = false
            status = "啟動失敗：\(error.localizedDescription)"
        }
    }

    func stop() {
        stop(updateStatus: true)
    }

    private func stop(updateStatus: Bool) {
        runID = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        if let entryProcess, entryProcess.isRunning {
            entryProcess.terminate()
        }
        entryProcess = nil
        isRunning = false
        if updateStatus { status = "已停止" }
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
        throw C2CError("找不到 c2c helper，請使用 scripts/package-app.sh 建立完整 App。")
    }
}

@main
private struct CodexWithChatGPTApp: App {
    @StateObject private var workspace = WorkspaceEntryModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        MenuBarExtra("Codex with ChatGPT", systemImage: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Codex with ChatGPT")
                    .font(.headline)

                if workspace.workspacePath.isEmpty {
                    Text("尚未選擇工作目錄")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(workspace.workspacePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Text(workspace.status)
                    .font(.caption)
                    .foregroundStyle(workspace.isRunning ? .green : .secondary)

                HStack {
                    Button("選擇工作目錄…") { workspace.chooseWorkspace() }
                    Button(workspace.isRunning ? "重新啟動" : "啟動") { workspace.start() }
                    if workspace.isRunning {
                        Button("停止") { workspace.stop() }
                    }
                }

                Divider()

                Picker("更新頻道", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button("檢查更新…") { updates.checkForUpdates() }
                    Spacer()
                    Button("結束") {
                        workspace.stop()
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(14)
            .frame(width: 390)
        }
        .menuBarExtraStyle(.window)
    }
}
