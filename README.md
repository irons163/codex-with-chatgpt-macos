# Codex with ChatGPT · Swift for macOS

原生 Swift／macOS 工具，讓 Codex session 能開啟或繼續對應的 ChatGPT Quick Chat，並透過 CDP 將經安全規則篩選的工作區檔案附加到對話。專案提供 menu bar App、`c2c` 命令列工具，以及 Sparkle 自動更新與 GitHub Release 流程。

**macOS 13 以上，Apple Silicon / Intel。無 Node.js 或 npm。** App 與 CLI 都只在本機透過 CDP 操作桌面版介面，不會啟動 HTTP server、OAuth、MCP 或公開連線；Sparkle 2 負責已簽署 App 的自動更新。

## 建置與執行

需要 Xcode Command Line Tools（`xcode-select --install`）以及 Swift 5.9 以上。通用架構建置使用完整 Xcode 的建置系統。

```sh
swift build
swift test
./scripts/build.sh                # dist/c2c，本機架構的 release 執行檔
./scripts/build.sh --universal    # Apple Silicon + Intel universal binary
./scripts/package-app.sh          # dist/CodexWithChatGPT.app（本機 ad-hoc 簽署）
./dist/c2c --help
```

正式 release 由 GitHub Actions 建置 Apple Silicon 與 Intel DMG、Developer ID 簽署、Apple notarization，並產生 Sparkle Ed25519 appcast。設定與發佈步驟見 [安全更新與 Release](docs/UPDATES.md)。

## App 使用方式

將 `CodexWithChatGPT.app` 放進 `/Applications` 後開啟，選擇工作目錄並按「啟動」。App 會常駐 menu bar，執行與 `c2c entry --workspace ...` 相同的 CDP 注入；也可選擇 Stable／Beta 更新頻道及手動檢查更新。App bundle 內仍包含 `Contents/Helpers/c2c`，終端機流程不受影響。

可在 Xcode 直接開啟 `Package.swift`。若要放進 PATH：

```sh
./scripts/install.sh             # 預設 ~/.local/bin/c2c
# 或 ./scripts/install.sh /your/prefix
```

安裝腳本不會修改 shell 設定或 Codex 設定。

## 使用（直接 CDP 注入）

在 Xcode 開啟 `Package.swift`、選擇 `c2c` scheme 後直接按 Run 即可；程式會把該
Swift Package 根目錄當成工作區，不必設定 Scheme arguments、連線服務或配對碼。從終端機啟動也只需：

```sh
cd /path/to/project
c2c
```

不帶命令時，`c2c` 會把目前目錄當成工作區，尋找既有的 Codex/ChatGPT CDP
debug port；若找不到，會以本機 debug port 重新啟動桌面 app，然後注入工作目錄入口。
需要指定其他工作區或 app 時才加參數：

```sh
c2c --workspace /path/to/project
c2c --workspace /path/to/project --app /Applications/ChatGPT.app
```

注入面板可另外選擇工作目錄；開始新的附件批次時會重新掃描磁碟，再透過 CDP
把目前的原始程式碼與文字檔附加到 ChatGPT／Quick Chat。它不會產生合併 Markdown，
但仍屬於當次附件，不是賦予雲端 ChatGPT 本機檔案工具。程序保持前景執行以維持 CDP 連線。

## 工作目錄入口（明確指定 entry 命令）

```sh
c2c entry --workspace /path/to/project        # 前景執行，Ctrl-C 結束
c2c entry --app /Applications/ChatGPT.app --debug-port 57330
```

`entry` 會以 Chrome DevTools Protocol 連上 Codex/ChatGPT 桌面版（與 theme-switcher 同款的 attach 方式：先沿用現有 debug 埠，否則以 `--remote-debugging-port` 重新啟動 app），在每個 session 加入 Quick Chat 入口，並在視窗右下注入一個可拖曳的工作目錄按鈕：

- **Session Quick Chat**：每個 Codex session 右側會多一個 Quick Chat 圖示。第一次按會建立該 session 的 ChatGPT 對話；送出訊息後會記住 conversation ID，之後從同一個 session 按下即可繼續。已綁定的 session 會在 Quick Chat 圖示左邊直接顯示「×」解除按鈕；解除後下次按 Quick Chat 圖示會建立新對話。對應關係只儲存在桌面 App 的 localStorage。
- **選擇工作目錄**：使用 macOS 原生目錄選擇視窗切換目前工作區。
- **編輯排除規則**：第一次按會在工作目錄建立完整且附有註解的 `.c2cignore`，並用文字編輯器開啟。安全檔案、依賴與 build cache 規則都在這份列表中，可使用類似 `.gitignore` 的語法增刪；舊格式的自訂規則會保留並合併。儲存後，下次建立附件批次時自動重新載入。
- **附加目前專案檔案**：先開啟 ChatGPT／Quick Chat，再掃描完整工作目錄，套用 ignore、文字檔驗證與敏感檔案排除規則後，以 CDP 設定 ChatGPT 的附件輸入。第一次會建立固定批次快照；依 ChatGPT 限制每批最多 20 個檔案，送出目前訊息後再按一次即可繼續。輸入框仍有附件時不會載入下一批。單檔上限 1 MiB、每批合計 8 MiB。

目前桌面 App 的「檔案和資料夾」會開啟 Electron 原生 `NSOpenPanel`，不會觸發 Chromium 的 `Page.fileChooserOpened`。此實作不模擬拖放，而是找出 ChatGPT／Quick Chat composer 的隱藏檔案輸入，再呼叫 CDP `DOM.setFileInputFiles` 指定原始檔案路徑；找不到 ChatGPT 附件輸入時會停止並提示先開啟 Quick Chat，不會退回附加到 Codex 主輸入框。Swift 端會排除 `.gitignore`、`.c2cignore`、`.env`、金鑰、憑證、`.git`、build cache 與 symlink。檔案變更後再按一次即可附加新版。Ctrl-C 或程序離開時會移除面板。

## 附件安全邊界

- 不啟動 HTTP server、OAuth、MCP、tunnel 或公開 listener。
- 只掃描所選工作目錄，工作區外檔案與 symlink 不會加入附件。
- `.c2cignore` 集中列出可查看、可修改的預設安全排除規則，並同時套用 `.gitignore`。
- 每批最多 20 個檔案與 8 MiB；單檔最多 1 MiB，且只接受可驗證的 UTF-8 文字檔。
- 附件是按下按鈕時的檔案內容，不會賦予 ChatGPT 持續讀取本機專案的權限。

附帶的 [操作 Skill](skill/SKILL.md) 提供 Swift/macOS 工作流程，尚未自動安裝至個人 Codex 設定。

## 授權

本專案採用 [MIT License](LICENSE)，且不是 OpenAI 官方產品。
