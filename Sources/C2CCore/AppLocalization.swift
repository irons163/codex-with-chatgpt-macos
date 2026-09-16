import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-TW"
    case simplifiedChinese = "zh-CN"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"

    public static func matchingCodexIdentifier(_ identifier: String?) -> AppLanguage {
        guard let identifier else { return .english }
        let value = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !value.isEmpty else { return .english }
        if value == "en" || value.hasPrefix("en-") { return .english }
        if value == "fr" || value.hasPrefix("fr-") { return .french }
        if value == "es" || value.hasPrefix("es-") { return .spanish }
        if value == "ja" || value.hasPrefix("ja-") { return .japanese }
        if value == "ko" || value.hasPrefix("ko-") { return .korean }
        if value == "zh" || value.hasPrefix("zh-") {
            if value.contains("hant") || value.contains("-tw") ||
                value.contains("-hk") || value.contains("-mo") {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }
        return .english
    }
}

public enum AppTextKey: String, CaseIterable, Sendable {
    case starting, stopped, processFailed, injecting, injected, startFailed
    case reinject, startInjection, checkUpdates, quit, helperMissing
    case sessionFallback, workspacePath, workspaceMissing
    case openNewQuickChat, continueQuickChat, attachProject, attachNextBatch, editExclusions
    case openProjectMenu, unlinkQuickChat, unlinkedQuickChat
    case quickChatEntryMissing, quickChatNotOpen, retryingBinding
    case boundChatUnavailable, boundChatLoadFailed, newChatButtonMissing, quickChatOpenFailed
    case connectionNotReady, processing, nativeCallFailed, invalidResponse
    case ignoreOpenedStatus, ignoreOpenedMessage, batchAttachedStatus
    case batchMoreMessage, skippedFilesSuffix, safeBatchesComplete, allBatchesComplete
    case cancelled, workspaceReadFailed
}

public enum AppLocalization {
    public static func text(
        _ key: AppTextKey,
        language: AppLanguage,
        replacements: [String: String] = [:]
    ) -> String {
        var value = catalog[language]?[key] ?? catalog[.english]?[key] ?? key.rawValue
        for (name, replacement) in replacements {
            value = value.replacingOccurrences(of: "{\(name)}", with: replacement)
        }
        return value
    }

    public static func hasCompleteCatalog(for language: AppLanguage) -> Bool {
        Set(catalog[language]?.keys.map { $0 } ?? []) == Set(AppTextKey.allCases)
    }

    public static var javascriptCatalog: String {
        let object = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { language in
            let strings = Dictionary(uniqueKeysWithValues: AppTextKey.allCases.map { key in
                (key.rawValue, text(key, language: language))
            })
            return (language.rawValue, strings)
        })
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static let catalog: [AppLanguage: [AppTextKey: String]] = [
        .english: [
            .starting: "Starting…", .stopped: "Stopped", .processFailed: "Failed (exit {code})",
            .injecting: "Injecting into Codex…", .injected: "Injected into Codex",
            .startFailed: "Could not start: {error}", .reinject: "Re-inject",
            .startInjection: "Start injection", .checkUpdates: "Check for Updates…", .quit: "Quit",
            .helperMissing: "The c2c helper is missing. Build a complete app with scripts/package-app.sh.",
            .sessionFallback: "This session", .workspacePath: "Working directory: {path}",
            .workspaceMissing: "No working directory was found for this session",
            .openNewQuickChat: "Open a new Quick Chat", .continueQuickChat: "Continue Quick Chat",
            .attachProject: "Attach “{workspace}” project files",
            .attachNextBatch: "Attach next batch after sending ({count} remaining)",
            .editExclusions: "Edit “{workspace}” exclusion rules…",
            .openProjectMenu: "Open the ChatGPT project menu for “{title}”",
            .unlinkQuickChat: "Unlink Quick Chat from “{title}”", .unlinkedQuickChat: "Quick Chat unlinked",
            .quickChatEntryMissing: "The built-in Quick Chat button could not be found",
            .quickChatNotOpen: "Quick Chat did not open",
            .retryingBinding: "Left the error screen and is retrying the original Quick Chat link.",
            .boundChatUnavailable: "The linked Quick Chat is not currently available. The link was kept; try again later or click × to unlink.",
            .boundChatLoadFailed: "The linked Quick Chat could not be loaded right now. The link was kept; try again later or click × to unlink.",
            .newChatButtonMissing: "The new-chat button could not be found in Quick Chat",
            .quickChatOpenFailed: "Could not open Quick Chat", .connectionNotReady: "The working-directory connection is not ready. Make sure c2c is still running.",
            .processing: "Working…", .nativeCallFailed: "Could not call c2c: {error}",
            .invalidResponse: "The c2c response could not be parsed.",
            .ignoreOpenedStatus: "Opened .c2cignore",
            .ignoreOpenedMessage: "The exclusion rules were opened in a text editor. Saved changes will be used the next time files are attached.",
            .batchAttachedStatus: "Attached batch {batch}/{total} ({count} files)",
            .batchMoreMessage: "Batch {batch}/{total} was attached. Send this message before attaching the next batch.",
            .skippedFilesSuffix: " Some files were omitted because they could not be read safely.",
            .safeBatchesComplete: "All safely readable batches are complete; some files were omitted.",
            .allBatchesComplete: "Batch {batch}/{total} was attached; all batches are complete.",
            .cancelled: "Cancelled.", .workspaceReadFailed: "Could not read the working directory."
        ],
        .traditionalChinese: [
            .starting: "正在啟動…", .stopped: "已停止", .processFailed: "執行失敗（exit {code}）",
            .injecting: "正在注入 Codex…", .injected: "已注入 Codex", .startFailed: "啟動失敗：{error}",
            .reinject: "重新注入", .startInjection: "啟動注入", .checkUpdates: "檢查更新…", .quit: "結束",
            .helperMissing: "找不到 c2c helper，請使用 scripts/package-app.sh 建立完整 App。",
            .sessionFallback: "這個 session", .workspacePath: "工作目錄：{path}",
            .workspaceMissing: "找不到這個 session 的工作目錄", .openNewQuickChat: "開啟新的 Quick Chat",
            .continueQuickChat: "繼續 Quick Chat", .attachProject: "附加「{workspace}」專案檔案",
            .attachNextBatch: "送出後附加下一批（剩 {count} 個）", .editExclusions: "編輯「{workspace}」排除規則…",
            .openProjectMenu: "開啟「{title}」的 ChatGPT 專案選單", .unlinkQuickChat: "解除「{title}」的 Quick Chat 綁定",
            .unlinkedQuickChat: "已解除 Quick Chat 綁定", .quickChatEntryMissing: "找不到內建 Quick Chat 入口",
            .quickChatNotOpen: "Quick Chat 未開啟", .retryingBinding: "已離開錯誤畫面，正在重試原本的 Quick Chat 綁定。",
            .boundChatUnavailable: "原本的 Quick Chat 對話目前不在可用清單；綁定已保留，可稍後重試或按 × 解綁",
            .boundChatLoadFailed: "原本的 Quick Chat 對話暫時無法載入；綁定已保留，可稍後重試或按 × 解綁",
            .newChatButtonMissing: "找不到 Quick Chat 的新對話按鈕", .quickChatOpenFailed: "Quick Chat 開啟失敗",
            .connectionNotReady: "工作目錄連線尚未就緒，請確認 c2c 仍在執行。", .processing: "處理中…",
            .nativeCallFailed: "無法呼叫 c2c：{error}", .invalidResponse: "c2c 回應無法解析。",
            .ignoreOpenedStatus: "已開啟 .c2cignore", .ignoreOpenedMessage: "排除規則已用文字編輯器開啟；儲存後，下次附加會自動重新載入。",
            .batchAttachedStatus: "已附加第 {batch}/{total} 批（{count} 個）",
            .batchMoreMessage: "第 {batch}/{total} 批已附加。請先送出這則訊息，再按下一批。",
            .skippedFilesSuffix: " 部分檔案因無法安全讀取而未列入。", .safeBatchesComplete: "可安全讀取的批次已完成；部分檔案未列入。",
            .allBatchesComplete: "第 {batch}/{total} 批已附加；全部批次完成。", .cancelled: "已取消。",
            .workspaceReadFailed: "讀取工作目錄失敗。"
        ],
        .simplifiedChinese: [
            .starting: "正在启动…", .stopped: "已停止", .processFailed: "运行失败（exit {code}）",
            .injecting: "正在注入 Codex…", .injected: "已注入 Codex", .startFailed: "启动失败：{error}",
            .reinject: "重新注入", .startInjection: "启动注入", .checkUpdates: "检查更新…", .quit: "退出",
            .helperMissing: "找不到 c2c helper，请使用 scripts/package-app.sh 创建完整 App。",
            .sessionFallback: "这个 session", .workspacePath: "工作目录：{path}",
            .workspaceMissing: "找不到这个 session 的工作目录", .openNewQuickChat: "打开新的 Quick Chat",
            .continueQuickChat: "继续 Quick Chat", .attachProject: "附加“{workspace}”项目文件",
            .attachNextBatch: "发送后附加下一批（剩余 {count} 个）", .editExclusions: "编辑“{workspace}”排除规则…",
            .openProjectMenu: "打开“{title}”的 ChatGPT 项目菜单", .unlinkQuickChat: "解除“{title}”的 Quick Chat 绑定",
            .unlinkedQuickChat: "已解除 Quick Chat 绑定", .quickChatEntryMissing: "找不到内置 Quick Chat 入口",
            .quickChatNotOpen: "Quick Chat 未打开", .retryingBinding: "已离开错误页面，正在重试原来的 Quick Chat 绑定。",
            .boundChatUnavailable: "绑定的 Quick Chat 当前不在可用列表中；绑定已保留，可稍后重试或点击 × 解除绑定。",
            .boundChatLoadFailed: "绑定的 Quick Chat 暂时无法加载；绑定已保留，可稍后重试或点击 × 解除绑定。",
            .newChatButtonMissing: "找不到 Quick Chat 的新对话按钮", .quickChatOpenFailed: "无法打开 Quick Chat",
            .connectionNotReady: "工作目录连接尚未就绪，请确认 c2c 仍在运行。", .processing: "处理中…",
            .nativeCallFailed: "无法调用 c2c：{error}", .invalidResponse: "无法解析 c2c 响应。",
            .ignoreOpenedStatus: "已打开 .c2cignore", .ignoreOpenedMessage: "排除规则已在文本编辑器中打开；保存后，下次附加时会自动重新加载。",
            .batchAttachedStatus: "已附加第 {batch}/{total} 批（{count} 个）",
            .batchMoreMessage: "第 {batch}/{total} 批已附加。请先发送这条消息，再附加下一批。",
            .skippedFilesSuffix: " 部分文件因无法安全读取而未包含。", .safeBatchesComplete: "可安全读取的批次已完成；部分文件未包含。",
            .allBatchesComplete: "第 {batch}/{total} 批已附加；全部批次完成。", .cancelled: "已取消。",
            .workspaceReadFailed: "读取工作目录失败。"
        ],
        .french: [
            .starting: "Démarrage…", .stopped: "Arrêté", .processFailed: "Échec (code {code})",
            .injecting: "Injection dans Codex…", .injected: "Injecté dans Codex", .startFailed: "Échec du démarrage : {error}",
            .reinject: "Réinjecter", .startInjection: "Démarrer l’injection", .checkUpdates: "Rechercher les mises à jour…", .quit: "Quitter",
            .helperMissing: "Le helper c2c est introuvable. Créez l’app complète avec scripts/package-app.sh.",
            .sessionFallback: "Cette session", .workspacePath: "Dossier de travail : {path}",
            .workspaceMissing: "Aucun dossier de travail trouvé pour cette session", .openNewQuickChat: "Ouvrir un nouveau Quick Chat",
            .continueQuickChat: "Continuer Quick Chat", .attachProject: "Joindre les fichiers du projet « {workspace} »",
            .attachNextBatch: "Joindre le lot suivant après l’envoi ({count} restants)", .editExclusions: "Modifier les exclusions de « {workspace} »…",
            .openProjectMenu: "Ouvrir le menu de projet ChatGPT pour « {title} »", .unlinkQuickChat: "Dissocier Quick Chat de « {title} »",
            .unlinkedQuickChat: "Quick Chat dissocié", .quickChatEntryMissing: "Le bouton Quick Chat intégré est introuvable",
            .quickChatNotOpen: "Quick Chat ne s’est pas ouvert", .retryingBinding: "Écran d’erreur quitté ; nouvelle tentative d’ouverture du Quick Chat associé.",
            .boundChatUnavailable: "Le Quick Chat associé n’est pas disponible. Le lien est conservé ; réessayez plus tard ou cliquez sur × pour le supprimer.",
            .boundChatLoadFailed: "Le Quick Chat associé ne peut pas être chargé. Le lien est conservé ; réessayez plus tard ou cliquez sur × pour le supprimer.",
            .newChatButtonMissing: "Le bouton de nouvelle conversation est introuvable dans Quick Chat", .quickChatOpenFailed: "Impossible d’ouvrir Quick Chat",
            .connectionNotReady: "La connexion au dossier de travail n’est pas prête. Vérifiez que c2c fonctionne toujours.", .processing: "Traitement…",
            .nativeCallFailed: "Impossible d’appeler c2c : {error}", .invalidResponse: "La réponse de c2c est illisible.",
            .ignoreOpenedStatus: ".c2cignore ouvert", .ignoreOpenedMessage: "Les exclusions ont été ouvertes dans un éditeur de texte. Les modifications seront appliquées au prochain ajout.",
            .batchAttachedStatus: "Lot {batch}/{total} joint ({count} fichiers)", .batchMoreMessage: "Lot {batch}/{total} joint. Envoyez ce message avant de joindre le lot suivant.",
            .skippedFilesSuffix: " Certains fichiers illisibles en toute sécurité ont été omis.", .safeBatchesComplete: "Tous les lots lisibles en toute sécurité sont terminés ; certains fichiers ont été omis.",
            .allBatchesComplete: "Lot {batch}/{total} joint ; tous les lots sont terminés.", .cancelled: "Annulé.",
            .workspaceReadFailed: "Impossible de lire le dossier de travail."
        ],
        .spanish: [
            .starting: "Iniciando…", .stopped: "Detenido", .processFailed: "Error (salida {code})",
            .injecting: "Inyectando en Codex…", .injected: "Inyectado en Codex", .startFailed: "No se pudo iniciar: {error}",
            .reinject: "Volver a inyectar", .startInjection: "Iniciar inyección", .checkUpdates: "Buscar actualizaciones…", .quit: "Salir",
            .helperMissing: "No se encontró el helper c2c. Crea la app completa con scripts/package-app.sh.",
            .sessionFallback: "Esta sesión", .workspacePath: "Directorio de trabajo: {path}",
            .workspaceMissing: "No se encontró el directorio de trabajo de esta sesión", .openNewQuickChat: "Abrir un Quick Chat nuevo",
            .continueQuickChat: "Continuar Quick Chat", .attachProject: "Adjuntar archivos del proyecto «{workspace}»",
            .attachNextBatch: "Adjuntar el siguiente lote después de enviar (quedan {count})", .editExclusions: "Editar exclusiones de «{workspace}»…",
            .openProjectMenu: "Abrir el menú de proyecto de ChatGPT para «{title}»", .unlinkQuickChat: "Desvincular Quick Chat de «{title}»",
            .unlinkedQuickChat: "Quick Chat desvinculado", .quickChatEntryMissing: "No se encontró el botón Quick Chat integrado",
            .quickChatNotOpen: "Quick Chat no se abrió", .retryingBinding: "Se cerró la pantalla de error; reintentando el Quick Chat vinculado.",
            .boundChatUnavailable: "El Quick Chat vinculado no está disponible. El vínculo se conserva; inténtalo más tarde o pulsa × para quitarlo.",
            .boundChatLoadFailed: "El Quick Chat vinculado no se puede cargar ahora. El vínculo se conserva; inténtalo más tarde o pulsa × para quitarlo.",
            .newChatButtonMissing: "No se encontró el botón de chat nuevo en Quick Chat", .quickChatOpenFailed: "No se pudo abrir Quick Chat",
            .connectionNotReady: "La conexión al directorio de trabajo no está lista. Comprueba que c2c siga ejecutándose.", .processing: "Procesando…",
            .nativeCallFailed: "No se pudo llamar a c2c: {error}", .invalidResponse: "No se pudo interpretar la respuesta de c2c.",
            .ignoreOpenedStatus: ".c2cignore abierto", .ignoreOpenedMessage: "Las exclusiones se abrieron en un editor de texto. Los cambios se aplicarán la próxima vez.",
            .batchAttachedStatus: "Lote {batch}/{total} adjuntado ({count} archivos)", .batchMoreMessage: "Lote {batch}/{total} adjuntado. Envía este mensaje antes de adjuntar el siguiente lote.",
            .skippedFilesSuffix: " Se omitieron algunos archivos porque no se pudieron leer de forma segura.", .safeBatchesComplete: "Se completaron todos los lotes legibles de forma segura; se omitieron algunos archivos.",
            .allBatchesComplete: "Lote {batch}/{total} adjuntado; se completaron todos los lotes.", .cancelled: "Cancelado.",
            .workspaceReadFailed: "No se pudo leer el directorio de trabajo."
        ],
        .japanese: [
            .starting: "起動中…", .stopped: "停止しました", .processFailed: "実行に失敗しました（exit {code}）",
            .injecting: "Codex に注入中…", .injected: "Codex に注入済み", .startFailed: "起動できませんでした：{error}",
            .reinject: "再注入", .startInjection: "注入を開始", .checkUpdates: "アップデートを確認…", .quit: "終了",
            .helperMissing: "c2c helper が見つかりません。scripts/package-app.sh で完全なアプリを作成してください。",
            .sessionFallback: "この session", .workspacePath: "作業ディレクトリ：{path}",
            .workspaceMissing: "この session の作業ディレクトリが見つかりません", .openNewQuickChat: "新しい Quick Chat を開く",
            .continueQuickChat: "Quick Chat を続ける", .attachProject: "「{workspace}」のプロジェクトファイルを添付",
            .attachNextBatch: "送信後に次の分を添付（残り {count} 件）", .editExclusions: "「{workspace}」の除外ルールを編集…",
            .openProjectMenu: "「{title}」の ChatGPT プロジェクトメニューを開く", .unlinkQuickChat: "「{title}」と Quick Chat の紐付けを解除",
            .unlinkedQuickChat: "Quick Chat の紐付けを解除しました", .quickChatEntryMissing: "標準の Quick Chat ボタンが見つかりません",
            .quickChatNotOpen: "Quick Chat が開きませんでした", .retryingBinding: "エラー画面を閉じ、紐付け済みの Quick Chat を再試行しています。",
            .boundChatUnavailable: "紐付け済みの Quick Chat は現在利用できません。紐付けは保持されています。後でもう一度試すか、× で解除してください。",
            .boundChatLoadFailed: "紐付け済みの Quick Chat を現在読み込めません。紐付けは保持されています。後でもう一度試すか、× で解除してください。",
            .newChatButtonMissing: "Quick Chat の新規チャットボタンが見つかりません", .quickChatOpenFailed: "Quick Chat を開けませんでした",
            .connectionNotReady: "作業ディレクトリへの接続準備ができていません。c2c が実行中か確認してください。", .processing: "処理中…",
            .nativeCallFailed: "c2c を呼び出せません：{error}", .invalidResponse: "c2c の応答を解析できません。",
            .ignoreOpenedStatus: ".c2cignore を開きました", .ignoreOpenedMessage: "除外ルールをテキストエディタで開きました。保存内容は次回の添付時に反映されます。",
            .batchAttachedStatus: "{batch}/{total} 番目を添付しました（{count} 件）", .batchMoreMessage: "{batch}/{total} 番目を添付しました。次を添付する前に、このメッセージを送信してください。",
            .skippedFilesSuffix: " 安全に読み取れない一部のファイルは除外されました。", .safeBatchesComplete: "安全に読み取れる分の添付が完了しました。一部のファイルは除外されました。",
            .allBatchesComplete: "{batch}/{total} 番目を添付しました。すべて完了しました。", .cancelled: "キャンセルしました。",
            .workspaceReadFailed: "作業ディレクトリを読み取れませんでした。"
        ],
        .korean: [
            .starting: "시작 중…", .stopped: "중지됨", .processFailed: "실행 실패(exit {code})",
            .injecting: "Codex에 주입 중…", .injected: "Codex에 주입됨", .startFailed: "시작 실패: {error}",
            .reinject: "다시 주입", .startInjection: "주입 시작", .checkUpdates: "업데이트 확인…", .quit: "종료",
            .helperMissing: "c2c helper를 찾을 수 없습니다. scripts/package-app.sh로 완전한 앱을 빌드하세요.",
            .sessionFallback: "이 session", .workspacePath: "작업 디렉터리: {path}",
            .workspaceMissing: "이 session의 작업 디렉터리를 찾을 수 없습니다", .openNewQuickChat: "새 Quick Chat 열기",
            .continueQuickChat: "Quick Chat 계속하기", .attachProject: "‘{workspace}’ 프로젝트 파일 첨부",
            .attachNextBatch: "전송 후 다음 배치 첨부(남은 파일 {count}개)", .editExclusions: "‘{workspace}’ 제외 규칙 편집…",
            .openProjectMenu: "‘{title}’의 ChatGPT 프로젝트 메뉴 열기", .unlinkQuickChat: "‘{title}’의 Quick Chat 연결 해제",
            .unlinkedQuickChat: "Quick Chat 연결이 해제됨", .quickChatEntryMissing: "기본 Quick Chat 버튼을 찾을 수 없습니다",
            .quickChatNotOpen: "Quick Chat이 열리지 않았습니다", .retryingBinding: "오류 화면을 벗어나 연결된 Quick Chat을 다시 시도합니다.",
            .boundChatUnavailable: "연결된 Quick Chat을 현재 사용할 수 없습니다. 연결은 유지됩니다. 나중에 다시 시도하거나 ×를 눌러 해제하세요.",
            .boundChatLoadFailed: "연결된 Quick Chat을 지금 불러올 수 없습니다. 연결은 유지됩니다. 나중에 다시 시도하거나 ×를 눌러 해제하세요.",
            .newChatButtonMissing: "Quick Chat의 새 채팅 버튼을 찾을 수 없습니다", .quickChatOpenFailed: "Quick Chat을 열 수 없습니다",
            .connectionNotReady: "작업 디렉터리 연결이 준비되지 않았습니다. c2c가 계속 실행 중인지 확인하세요.", .processing: "처리 중…",
            .nativeCallFailed: "c2c를 호출할 수 없습니다: {error}", .invalidResponse: "c2c 응답을 해석할 수 없습니다.",
            .ignoreOpenedStatus: ".c2cignore를 열었습니다", .ignoreOpenedMessage: "제외 규칙을 텍스트 편집기에서 열었습니다. 저장된 내용은 다음 첨부 때 적용됩니다.",
            .batchAttachedStatus: "{batch}/{total} 배치 첨부됨({count}개)", .batchMoreMessage: "{batch}/{total} 배치를 첨부했습니다. 다음 배치를 첨부하기 전에 이 메시지를 보내세요.",
            .skippedFilesSuffix: " 안전하게 읽을 수 없는 일부 파일은 제외되었습니다.", .safeBatchesComplete: "안전하게 읽을 수 있는 모든 배치를 완료했습니다. 일부 파일은 제외되었습니다.",
            .allBatchesComplete: "{batch}/{total} 배치를 첨부했습니다. 모든 배치가 완료되었습니다.", .cancelled: "취소되었습니다.",
            .workspaceReadFailed: "작업 디렉터리를 읽을 수 없습니다."
        ]
    ]
}
