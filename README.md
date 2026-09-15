# Codex with ChatGPT · Swift for macOS

讓 Codex 與 ChatGPT Quick Chat 接得更順的 macOS App。

一般流程是先在 Quick Chat 討論，再按「新增至 Codex」執行；但 ChatGPT 與 Codex 是兩套不同的系統，之後要回到剛才的對話，通常得自己重新翻找。這個 App 會在每個 Codex session 旁加入操作按鈕，第一次按可開啟 Quick Chat，聊過後再按則會回到同一串對話。

需要讓 ChatGPT 看專案時，也能從同一入口附加該 session 工作目錄中的檔案。檔案太多會自動分批，敏感內容可透過 `.c2cignore` 排除。開啟 App 後即會自動注入；不使用這些按鈕時，原本的 Codex／ChatGPT 操作方式不受影響。

![Codex session 的 Quick Chat、專案附件與排除規則選單](docs/images/session-quick-chat-actions.png)

**macOS 13 以上，Apple Silicon / Intel。無 Node.js 或 npm。** App 與 CLI 都只在本機透過 CDP 操作桌面版介面，不會啟動 HTTP server、OAuth、MCP 或公開連線；Sparkle 2 負責已簽署 App 的自動更新。

## 下載與安裝

目前版本：**v0.1.2**

- [下載 Apple Silicon 版（M1／M2／M3／M4）](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [下載 Intel 版](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [查看最新版與更新紀錄](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

開啟 DMG，將 `CodexWithChatGPT.app` 拖進 `/Applications`，再直接啟動即可。App 已經過 Developer ID 簽署與 Apple notarization，之後可透過內建的 Sparkle 檢查更新。

## App 使用方式

將 `CodexWithChatGPT.app` 放進 `/Applications` 後直接開啟，App 會自動在背景啟動 CDP 注入並常駐 menu bar，不必先選擇全域工作目錄。每個 Codex session 的操作入口會使用該 session 自己的 `displayCwd`。Menu bar 的精簡選單提供狀態、重新注入、檢查 Stable 更新與結束；App bundle 內仍包含 `Contents/Helpers/c2c`，終端機流程不受影響。

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
