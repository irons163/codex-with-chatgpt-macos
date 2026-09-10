import Foundation

/// Machine-wide ChatGPT setup choices.
public enum Preferences {
    public static let setupChoicePrompt = [
        "首次连接 ChatGPT 前，请选择一种配置方式（选一次即可，之后默认沿用）：",
        "",
        "**1. AI 自动化配置（预览版）**",
        "由我在内置浏览器里完成全部设置，你只需在需要登录、验证码或二次确认时操作一次。",
        "优点：几乎不用自己点页面。",
        "缺点：步骤多，整体更慢；若自动设置连续两次无法完成，会改为「手动教学配置」。",
        "",
        "**2. 手动教学配置**",
        "我逐步告诉你打开哪个页面、填写哪几项，由你在浏览器里完成点击。",
        "优点：大约 3 分钟可以完成，过程可控、更稳定。",
        "缺点：需要你按提示操作，不能完全放手。",
        "",
        "请回复「1」或「2」。未说明时，不要自行开始配置。",
    ].joined(separator: "\n")

    private static let setupModes: Set<String> = ["auto", "manual"]
    private static let optionNames: Set<String> = ["setup-mode"]
    private static let flagNames: Set<String> = ["developer-mode"]

    public static func get(stateDirectory: URL) -> [String: Any] {
        let stored = readStored(stateDirectory: stateDirectory)
        let developerModeEnabled = stored.developerModeEnabled
        let setupMode = stored.setupMode
        return [
            "developerModeEnabled": developerModeEnabled,
            "setupMode": setupMode ?? NSNull(),
            "setupChoicePrompt": setupChoicePrompt,
            "remembered": [
                "developerMode": developerModeEnabled,
                "setupMode": setupMode != nil,
            ],
        ]
    }

    @discardableResult
    public static func set(
        options: [String: String],
        flags: Set<String>,
        stateDirectory: URL
    ) throws -> [String: Any] {
        // Shared CLI options are consumed by the command dispatcher.  The
        // dispatcher currently forwards them too, so they must not become
        // preference keys or fail command-specific validation.
        let stateOptions = options.filter { $0.key != "workspace" && $0.key != "json" }
        let stateFlags = flags.subtracting(["json"])
        if let unknown = stateOptions.keys.filter({ !optionNames.contains($0) }).sorted().first {
            throw PreferencesError.invalidArgument("unknown preferences option: \(unknown)")
        }
        if let unknown = stateFlags.filter({ !flagNames.contains($0) }).sorted().first {
            throw PreferencesError.invalidArgument("unknown preferences flag: \(unknown)")
        }

        let mode: String?
        if let rawMode = stateOptions["setup-mode"] {
            let normalized = rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard setupModes.contains(normalized) else {
                throw PreferencesError.invalidArgument("setup-mode must be one of auto, manual")
            }
            mode = normalized
        } else {
            mode = nil
        }

        let developerMode = stateFlags.contains("developer-mode")
        guard developerMode || mode != nil else {
            throw PreferencesError.invalidArgument("nothing to save: pass --developer-mode and/or --setup-mode")
        }

        let previous = readStored(stateDirectory: stateDirectory)
        var stored: [String: Any] = ["updatedAt": nowISO8601()]
        if developerMode || previous.developerModeEnabled {
            stored["developerModeEnabled"] = true
        }
        if let mode {
            stored["setupMode"] = mode
        } else if let previousMode = previous.setupMode {
            stored["setupMode"] = previousMode
        }

        let prefsURL = stateDirectory.standardizedFileURL.appendingPathComponent("prefs.json")
        try AppPaths.writeJSON(stored, to: prefsURL)
        return get(stateDirectory: stateDirectory)
    }

    private struct Stored {
        let developerModeEnabled: Bool
        let setupMode: String?
    }

    private static func readStored(stateDirectory: URL) -> Stored {
        guard let raw = AppPaths.readJSON(
            stateDirectory.standardizedFileURL.appendingPathComponent("prefs.json")
        ) else {
            return Stored(developerModeEnabled: false, setupMode: nil)
        }

        let developerModeEnabled = boolValue(raw["developerModeEnabled"])
        let rawMode = raw["setupMode"] as? String
        let setupMode = rawMode.flatMap { setupModes.contains($0) ? $0 : nil }
        return Stored(developerModeEnabled: developerModeEnabled, setupMode: setupMode)
    }

    private static func boolValue(_ value: Any?) -> Bool {
        // The source JSON reader checks `=== true`, so numeric values such as
        // `1` in a damaged/hand-edited prefs file must not count as enabled.
        guard let number = value as? NSNumber else { return false }
        return String(cString: number.objCType) == "c" && number.boolValue
    }

    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

public enum PreferencesError: Error, LocalizedError, Equatable {
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        }
    }
}
