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
debug port；若找不到，會以本機 debug port 重新啟動桌面 app，然後注入 session 操作入口。
需要指定其他工作區或 app 時才加參數：

```sh
c2c --workspace /path/to/project
c2c --workspace /path/to/project --app /Applications/ChatGPT.app
```

Session 選單會從 Codex 提供的 `displayCwd` 取得該 session 的實際工作目錄；開始新的附件批次時會重新掃描該目錄，再透過 CDP
把目前的原始程式碼與文字檔附加到 ChatGPT／Quick Chat。它不會產生合併 Markdown，
但仍屬於當次附件，不是賦予雲端 ChatGPT 本機檔案工具。程序保持前景執行以維持 CDP 連線。

## 工作目錄入口（明確指定 entry 命令）

```sh
c2c entry --workspace /path/to/project        # 前景執行，Ctrl-C 結束
c2c entry --app /Applications/ChatGPT.app --debug-port 57330
```

`entry` 會以 Chrome DevTools Protocol 連上 Codex/ChatGPT 桌面版（與 theme-switcher 同款的 attach 方式：先沿用現有 debug 埠，否則以 `--remote-debugging-port` 重新啟動 app），在每個 session 加入專案操作入口：

- **開啟／繼續 Quick Chat**：按 session 右側的圖示會顯示該 session 的專案選單。第一次可建立 ChatGPT 對話；送出訊息後會記住 conversation ID，之後可從同一個 session 繼續。已綁定的 session 仍會顯示「×」解除按鈕。對應關係只儲存在桌面 App 的 localStorage。
- **附加專案檔案**：在同一個 session 選單中執行；程式會先開啟該 session 的 Quick Chat，再掃描該 session 的實際 `displayCwd`，套用 ignore、文字檔驗證與敏感檔案排除規則後，以 CDP 設定附件輸入。附件佇列以 session 分開保存；依 ChatGPT 限制每批最多 20 個檔案，送出目前訊息後再從同一選單繼續下一批。輸入框仍有附件時不會載入下一批。單檔上限 1 MiB、每批合計 8 MiB。若 Codex 沒有提供可驗證的工作目錄，該 session 不開放檔案操作。
- **編輯排除規則**：在同一個 session 選單中開啟該 session 工作目錄的 `.c2cignore`。第一次會建立完整且附有註解的安全規則；可使用類似 `.gitignore` 的語法增刪。儲存後，下次建立附件批次時自動重新載入。

目前桌面 App 的「檔案和資料夾」會開啟 Electron 原生 `NSOpenPanel`，不會觸發 Chromium 的 `Page.fileChooserOpened`。此實作不模擬拖放，而是找出 ChatGPT／Quick Chat composer 的隱藏檔案輸入，再呼叫 CDP `DOM.setFileInputFiles` 指定原始檔案路徑；找不到 ChatGPT 附件輸入時會停止，不會退回附加到 Codex 主輸入框。Swift 端會排除 `.gitignore`、`.c2cignore`、`.env`、金鑰、憑證、`.git`、build cache 與 symlink。檔案變更後再按一次即可附加新版。Ctrl-C 或程序離開時會移除注入的 session 入口。

## 附件安全邊界

- 不啟動 HTTP server、OAuth、MCP、tunnel 或公開 listener。
- 只掃描所選工作目錄，工作區外檔案與 symlink 不會加入附件。
- `.c2cignore` 集中列出可查看、可修改的預設安全排除規則，並同時套用 `.gitignore`。
- 每批最多 20 個檔案與 8 MiB；單檔最多 1 MiB，且只接受可驗證的 UTF-8 文字檔。
- 附件是按下按鈕時的檔案內容，不會賦予 ChatGPT 持續讀取本機專案的權限。

附帶的 [操作 Skill](skill/SKILL.md) 提供 Swift/macOS 工作流程，尚未自動安裝至個人 Codex 設定。

## 授權

本專案採用 [MIT License](LICENSE)，且不是 OpenAI 官方產品。
