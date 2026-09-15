# Codex with ChatGPT · Swift for macOS

[English](README.md) | [繁體中文](README.zh-TW.md) | **简体中文** | [Français](README.fr.md) | [Español](README.es.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

让 Codex 与 ChatGPT Quick Chat 衔接得更顺畅的 macOS App。

一般的使用流程是先在 Quick Chat 中讨论，再点击“添加到 Codex”执行；但 ChatGPT 和 Codex 是两套不同的系统，之后想回到刚才的对话，通常需要自己重新查找。这个 App 会在每个 Codex session 旁添加操作按钮：第一次点击可以打开 Quick Chat，聊过之后再点，就会回到同一段对话。

需要让 ChatGPT 查看项目时，也可以从同一个入口附加该 session 工作目录中的文件。文件太多时会自动分批，敏感内容可通过 `.c2cignore` 排除。打开 App 后会自动注入这些按钮；不使用时，原本的 Codex／ChatGPT 操作方式不会受到影响。

![Codex session 的 Quick Chat、项目附件与排除规则菜单](docs/images/session-quick-chat-actions.png)

**需要 macOS 13 或更高版本，支持 Apple Silicon 和 Intel，无需 Node.js 或 npm。** App 和 CLI 只在本机通过 CDP 操作桌面界面，不会启动 HTTP server、OAuth、MCP、tunnel 或公开连接；Sparkle 2 用于已签名 App 的自动更新。

## 下载与安装

当前版本：**v0.1.2**

- [下载 Apple Silicon 版（M1／M2／M3／M4）](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [下载 Intel 版](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [查看最新版本与更新记录](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

打开 DMG，将 `CodexWithChatGPT.app` 拖入 `/Applications`，然后直接启动。App 已通过 Developer ID 签名和 Apple 公证，之后可使用内置的 Sparkle 检查更新。

## 使用方法

1. 打开 Codex，再启动 `CodexWithChatGPT.app`。App 会常驻菜单栏，并自动为 session 添加操作按钮。
2. 点击任一 Codex session 右侧的图标。
3. 从菜单中选择需要的操作：
   - **打开／继续 Quick Chat**：第一次会创建对话，之后再次点击会回到同一段对话。
   - **附加项目文件**：将该 session 工作目录中的源代码和文本文件附加到 Quick Chat。
   - **编辑排除规则**：打开项目的 `.c2cignore`，调整永远不应附加的文件。

Quick Chat 绑定后，可点击 session 旁的“×”解除绑定。超过 20 个文件时会自动分批；发送当前消息后，再次选择“附加项目文件”即可载入下一批。

如果按钮没有出现，请从菜单栏 App 中选择“重新注入”。

## 附件安全边界

- 不会启动 HTTP server、OAuth、MCP、tunnel 或公开 listener。
- 只扫描该 session 的工作目录；目录外的文件和符号链接不会被附加。
- `.c2cignore` 集中列出可查看、可修改的默认安全排除规则，同时也会应用 `.gitignore`。
- 每批最多 20 个文件、总计 8 MiB；单个文件最多 1 MiB，且必须是有效的 UTF-8 文本。
- 附件内容取自点击按钮的当下，不会授予 ChatGPT 持续读取本地项目的权限。

附带的[操作 Skill](skill/SKILL.md)提供 Swift/macOS 工作流程，不会自动安装到个人 Codex 配置中。

## 许可证

本项目采用 [MIT License](LICENSE)，并非 OpenAI 官方产品。
