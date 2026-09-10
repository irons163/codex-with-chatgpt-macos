# Codex with ChatGPT · Swift for macOS

將 `codex-with-chatgpt` 的 TypeScript CLI 與唯讀 MCP 橋接服務移植為原生 Swift。ChatGPT 負責規劃與審查，Codex 執行程式修改；ChatGPT 透過經授權的 MCP 工具讀取工作區。

**macOS 13 以上，Apple Silicon / Intel。無 Node.js、npm 或第三方 Swift 套件依賴。** 這個專案保留原本的 `c2c` 命令列操作模式，以 Swift 標準工具鏈建置。公開連線另外需要 `cloudflared`。

## 建置與執行

需要 Xcode Command Line Tools（`xcode-select --install`）以及 Swift 5.9 以上。通用架構建置使用完整 Xcode 的建置系統。

```sh
swift build
swift test
./scripts/build.sh                # dist/c2c，本機架構的 release 執行檔
./scripts/build.sh --universal    # Apple Silicon + Intel universal binary
./dist/c2c --help
```

可在 Xcode 直接開啟 `Package.swift`。若要放進 PATH：

```sh
./scripts/install.sh             # 預設 ~/.local/bin/c2c
# 或 ./scripts/install.sh /your/prefix
```

安裝腳本不會修改 shell 設定、Codex 設定或 ChatGPT 連線。

## 使用

```sh
c2c workspace --workspace /path/to/project --json
c2c start --workspace /path/to/project --json
c2c setup --workspace /path/to/project --no-tunnel --json
c2c status --workspace /path/to/project --json
c2c doctor --workspace /path/to/project --no-fix --json
c2c stop --workspace /path/to/project --json
```

`start` 預設只啟動本機橋接；`setup` 預設也建立公開連線並產生五分鐘有效的配對碼。`setup --no-tunnel` 適合本機開發，ChatGPT 遠端連接需使用公開 HTTPS 位址。

```sh
brew install cloudflared
c2c setup --workspace /path/to/project --json
```

在 ChatGPT 的 MCP 連線設定加入輸出的 `mcpUrl`，選擇 OAuth，於授權頁輸入 `pairingCode`。登入與建立 ChatGPT 連線仍由使用者或 Codex 的瀏覽器工具完成，CLI 不接觸瀏覽器 cookie。

固定網址可用：

```sh
c2c tunnel choose --mode named --zone example.com --workspace /path/to/project
c2c start --tunnel --workspace /path/to/project
```

這個命令會使用 Cloudflare 登入、建立 Tunnel 與 DNS 路由。若選擇臨時網址：`c2c tunnel choose --mode quick`。Named 設定失敗會回報錯誤，不會悄悄切換或覆蓋既有設定。

## 命令與狀態

保留 `setup`、`start`、`serve`、`stop`、`restart`、`status`、`doctor`、`pair`、`unpair`、`logs`、`workspace`、`entry`、`sandbox-allow`、`update-check`、`session`、`prefs`、`record`、`tunnel`。完整參數見 `c2c --help`。

## 上傳入口（CDP 注入）

```sh
c2c entry --workspace /path/to/project        # 前景執行，Ctrl-C 結束
c2c entry --app /Applications/ChatGPT.app --debug-port 57330
```

`entry` 會以 Chrome DevTools Protocol 連上 Codex/ChatGPT 桌面版（與 theme-switcher 同款的 attach 方式：先沿用現有 debug 埠，否則以 `--remote-debugging-port` 重新啟動 app），在視窗右下注入一個可拖曳的浮動按鈕，提供兩個動作：

- **附加檔案到目前對話**：點擊 app 自己的 `<input type="file">`，完全走原生附檔流程。
- **上傳檔案到工作區**：渲染器只發出「使用者點了」的 CDP binding 訊號；檔案由原生端 `osascript` 檔案挑選視窗選取（OS 層使用者同意），再複製進 `<workspace>/uploads/`（同名自動加 `-1`、`-2`）。

安全屬性：MCP 工具維持唯讀、bridge 不新增任何端點；渲染器無法指定路徑或內容，寫入目的地永遠在工作區 `uploads/` 內並檢查 symlink 逃逸。Ctrl-C 或程序離開時會自動移除注入的面板；app 更新造成的 selector 漂移只影響「附加到對話」（找不到檔案輸入欄時會提示），不影響工作區上傳。同一時間只會有一個檔案挑選視窗。

```sh
c2c session set --mode project --project-url 'https://chatgpt.com/g/g-p-example/project'
c2c session get --json
c2c record --task task-1 --iteration 1 --changed-files 2 \
  --tests 'swift test passed' --command 'swift test' --output-file /tmp/test.log --exit-code 0
```

Swift 版預設狀態位於 `~/Library/Application Support/codex-with-chatgpt-macos/`，與原 TypeScript 安裝分開。`C2C_STATE_DIR` 可指定測試或自訂目錄；`C2C_CODEX_CONFIG` 可指定測試用 Codex 設定檔。狀態目錄採 `0700`、憑證與紀錄檔採 `0600`。

`setup`、`doctor`（未加 `--no-fix`）與 `sandbox-allow` 會將狀態目錄加入 Codex 的 `sandbox_workspace_write.writable_roots`。`doctor --no-fix` 僅檢查。Swift 版需要重新配對；不要把執行中的 TypeScript runtime/token 檔案直接複製過來。

## 唯讀工具與安全邊界

MCP 提供九個工具：`workspace_info`、`list_directory`、`read_file`、`search_workspace`、`git_status`、`git_diff`、`test_status`、`execution_summary`、`execution_output`。

- HTTP 僅綁定 `127.0.0.1`；公開連線由 Cloudflare Tunnel 提供。
- OAuth 使用配對碼、PKCE S256、工作區與工具 scope 檢查。
- 敏感檔案、工作區外路徑與逃逸 symlink 不可讀取；`.c2cignore` 可再增加排除規則。
- 執行輸出經命令白名單與敏感內容清洗後才可由 MCP 讀取。
- MCP 沒有寫入、刪除或執行 shell 的工具。CLI 的 `record` 只儲存 Codex 提供的執行證據，不會執行 `--command`。
- 背景服務採工作區鎖、身分驗證與私有 admin token，狀態不明時不會啟動第二份或向未知 PID 發送終止訊號。

實作對照及驗證範圍見 [docs/migration.md](docs/migration.md)。附帶的 [操作 Skill](skill/SKILL.md) 已改為 Swift/macOS 工作流程，尚未自動安裝至個人 Codex 設定。

## 原始專案與授權

移植來源為同工作區中的 `codex-with-chatgpt` 0.1.1，保留 [MIT LICENSE](LICENSE)。本專案不是 OpenAI 官方產品。
