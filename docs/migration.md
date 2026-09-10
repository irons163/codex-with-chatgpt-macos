# Swift／macOS 移植說明

來源：`codex-with-chatgpt` 0.1.1 的 TypeScript 實作。目標：macOS 13+ 的 Swift Package，維持 CLI／背景橋接／Codex Skill 的分工。

## 模組對照

| 原始模組 | Swift 實作 |
| --- | --- |
| `src/cli/index.ts` | `Sources/c2c/CLI.swift` |
| `src/bridge`、`src/process` | `Bridge.swift`、`HTTP.swift` |
| `src/auth`、`src/pairing` | `Auth.swift` |
| `src/mcp`、`src/workspace` | `MCP.swift`、`Workspace.swift` |
| `src/execution` | `Execution.swift` |
| `src/session` | `Session.swift` |
| `src/config` | `Core.swift`、`Preferences.swift`、`Sandbox.swift` |
| `src/tunnel` | `Tunnel.swift` |
| `skill/SKILL.md` | macOS／Swift 操作流程，仍由 Codex 宿主操作 ChatGPT 網頁 |

Foundation 處理檔案、JSON、程序與 HTTP client；Darwin 處理本機 socket、檔案鎖及安全檔案開啟；CryptoKit／Security 提供雜湊及安全亂數。原始專案沒有內建 CDP 瀏覽器 runtime，Swift 版也將 ChatGPT UI 操作留給宿主的瀏覽器工具。

## 保留的行為

- 一個工作區一個橋接服務，預設本機埠衝突時改用可用埠。
- 狀態辨識為正常、停止、不確定；不確定時拒絕重複啟動。
- OAuth discovery、動態 client 註冊、PKCE S256、一次性配對碼、token 更新與撤銷。
- 九個 MCP 唯讀工具、scope 檢查、JSON 結果及文字結果。
- 工作區讀取、目錄與 diff 分頁、搜尋、Git 狀態、執行紀錄與清洗後輸出。
- ChatGPT Project／長對話模式、checkpoint、偏好設定。
- Cloudflare Quick／Named Tunnel，以及公開網址變更時的連線修復資訊。

## 有意調整與限制

- 僅支援 macOS；交付 Mach-O CLI，不含獨立 SwiftUI 視窗。執行時無 Node.js／npm 依賴。
- 狀態預設移到 `codex-with-chatgpt-macos` 目錄。OAuth 持久化格式改為 Swift 版本，必須重新配對；不自動匯入舊 token、runtime 或正在執行的橋接。
- 一般 macOS 磁碟的工作區 ID 保留小寫 canonical path 的 SHA-256 前 12 位。區分大小寫的 volume 使用實際 canonical path，避免不同工作區共用 ID。
- PKCE 格式、scope、redirect URI、resource audience 與 MCP 參數檢查更嚴格。Refresh token 重播會撤銷同族後續 token。
- HTTP 只提供 stateless JSON Streamable HTTP，不建立持久 MCP session 或伺服器主動 SSE 串流。最大請求本文 8 MiB，同時處理最多 32 個連線。
- 配對與 OAuth 入口具有容量／頻率限制。由於實際 socket peer 是本機 Tunnel 程序，限流採共享配額，不以未驗證的 forwarded IP 放寬限制。
- 檔案必須是工作區內的一般文字檔；單檔讀取上限 16 MiB，搜尋略過超過 2 MiB 的檔案。`.git` 直接內容不可由 MCP 讀取；Git 工具停用 external diff、textconv 與 fsmonitor。
- 搜尋由原生 Swift 實作，回傳 `engine: "swift"`。包含基本 glob／ignore 規則；這不是原 `ignore` npm 套件或 ripgrep 的完整相容實作。Regex 限 128 bytes，拒絕高風險巢狀結構，每行搜尋前 4096 個字元；一般文字搜尋仍使用完整行。
- Named Tunnel 設定失敗會回報錯誤並保留既有選擇，不會自動降級成 Quick。DNS route 失敗不會僅因錯誤文字含「already exists」就宣稱成功。
- CLI 文字輸出與部分 JSON 輔助欄位經整理；`skill/SKILL.md` 已對應新的流程。
- `update-check` 只查本 Swift checkout 設定的 upstream，不會從 TypeScript upstream 覆寫 Swift 版。此交付目錄尚未設定遠端 Git repository。
- Binary 為本機 ad-hoc code signing，未使用 Developer ID 發行簽章／公證。

## 驗證範圍

XCTest 覆蓋配對／OAuth／scope／token 重播、HTTP 解析、真實本機 HTTP 的 OAuth→MCP 流程、工作區與 symlink 邊界、敏感檔案／Git diff、MCP 參數與分頁、執行輸出清洗、會話／偏好／TOML 設定、模擬 Tunnel 子程序、CLI 本機 setup／復用／status／doctor／stop。

CLI 測試透過 `C2C_STATE_DIR` 與 `C2C_CODEX_CONFIG` 使用臨時目錄；單元測試不需要 ChatGPT 或 Cloudflare 帳號。建置腳本支援 ARM64 與 x86_64 universal binary。

尚未使用真實帳號驗證 ChatGPT 連接器或 Cloudflare Named Tunnel／DNS。這些服務需要使用者登入及實際設定，不能以本機測試通過替代線上驗證。

### 本次驗收結果

- `swift test`：56 項測試通過，0 failures。
- `scripts/build.sh --universal`：Release 建置成功，無編譯警告。
- `lipo -archs dist/c2c`：`x86_64 arm64`。
- `codesign --verify --verbose dist/c2c`：簽章驗證通過。
- `arch -arm64` 與 `arch -x86_64` 啟動版本命令均通過；Intel 模式在 Apple Silicon 主機透過 Rosetta 驗證。
- 最終 Release 執行檔完成隔離環境中的 setup、daemon reuse、status、doctor、stop smoke test，測試服務已停止。
- 附帶 Skill 通過 `quick_validate.py`。

驗證環境為 Apple Swift 6.3／Apple Silicon macOS，通用建置使用 macOS 26.4 SDK；最低支援版本設定為 macOS 13，未另以 macOS 13 實機驗證。
