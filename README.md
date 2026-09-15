# Codex with ChatGPT · Swift for macOS

**English** | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

A macOS app that makes switching between Codex and ChatGPT Quick Chat less of a chore.

A typical workflow starts with a discussion in Quick Chat, followed by “Add to Codex” when it is time to implement. Because ChatGPT and Codex are separate systems, returning to that conversation later usually means finding it again yourself. This app adds an action button beside every Codex session: click it once to open Quick Chat, then click it again later to return to the same conversation.

You can also attach files from that session’s working directory when ChatGPT needs project context. Large file sets are split into batches automatically, and sensitive files can be excluded with `.c2cignore`. The buttons are injected when the app opens; the original Codex and ChatGPT workflows remain unchanged when you do not use them.

![Quick Chat, project attachment, and exclusion-rule actions for a Codex session](docs/images/session-quick-chat-actions.png)

**Requires macOS 13 or later. Supports Apple Silicon and Intel. No Node.js or npm.** The app and CLI interact with the desktop UI locally through CDP. They do not start an HTTP server, OAuth flow, MCP service, tunnel, or public connection. Sparkle 2 provides signed automatic updates.

## Download and install

Current version: **v0.1.2**

- [Download for Apple Silicon (M1/M2/M3/M4)](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [Download for Intel](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [View the latest release and changelog](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

Open the DMG, drag `CodexWithChatGPT.app` into `/Applications`, and launch it. The app is Developer ID signed and notarized by Apple. Future updates are available through the built-in Sparkle updater.

## Usage

1. Open Codex, then launch `CodexWithChatGPT.app`. It stays in the menu bar and adds action buttons to your sessions automatically.
2. Click the icon on the right side of any Codex session.
3. Choose an action:
   - **Open/Continue Quick Chat**: creates a conversation the first time and returns to the same conversation afterward.
   - **Attach project files**: attaches source and text files from that session’s working directory to Quick Chat.
   - **Edit exclusion rules**: opens the project’s `.c2cignore` so you can control which files are never attached.

After a Quick Chat is linked, click the “×” beside the session to unlink it. More than 20 files are split into batches automatically. Send the current message, then choose “Attach project files” again to load the next batch.

If the buttons do not appear, choose “Re-inject” from the menu bar app.

## Attachment security boundaries

- Does not start an HTTP server, OAuth flow, MCP service, tunnel, or public listener.
- Scans only the session’s working directory; files outside it and symlinks are never attached.
- `.c2cignore` contains visible, editable default safety exclusions, and `.gitignore` is applied as well.
- Each batch is limited to 20 files and 8 MiB. Each file is limited to 1 MiB and must be valid UTF-8 text.
- Attachments contain the file contents at the moment you click the button. They do not give ChatGPT ongoing access to your local project.

The included [operation skill](skill/SKILL.md) provides a Swift/macOS workflow and is not installed into your personal Codex configuration automatically.

## License

This project is available under the [MIT License](LICENSE) and is not an official OpenAI product.
