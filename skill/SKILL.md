---
name: codex-with-chatgpt-macos
description: Use the native macOS c2c app or CLI to add per-session ChatGPT Quick Chat controls and attach safely filtered workspace files over CDP.
---

# Codex with ChatGPT for macOS

Use this skill when the user wants a Codex session to open or resume a matching ChatGPT Quick Chat, or wants to attach files from a local workspace to that chat.

## Run

Build the project with Swift 5.9 or newer:

```sh
swift build
swift test
./scripts/package-app.sh
```

Run `dist/CodexWithChatGPT.app`, choose a workspace, and start the helper. For a terminal workflow, run:

```sh
c2c --workspace /path/to/project
```

The helper connects to the local Codex or ChatGPT desktop renderer over Chrome DevTools Protocol. It reuses an existing debug port when possible and may relaunch the desktop app with a local debugging port when needed. It does not start an MCP server, OAuth service, tunnel, or public listener.

## Quick Chat

Each detected Codex session gets a Quick Chat button. The first click creates a ChatGPT conversation for that session. After the conversation ID is observed, later clicks resume the same conversation. The adjacent unlink control removes only the local association; it does not delete either conversation.

Bindings are stored in the desktop renderer's localStorage. Do not claim that binding alone grants ChatGPT live filesystem access.

## Workspace attachments

The injected workspace panel can choose a directory, edit `.c2cignore`, and attach current project files. Attachment behavior has these invariants:

- Files are rescanned when a new batch queue starts.
- At most 20 files and 8 MiB are attached per batch; each file is at most 1 MiB.
- The next batch is blocked while the composer still contains attachments.
- Binary files, symlinks, ignored paths, credentials, environment files, dependencies, and build output are excluded.
- `.c2cignore` is the user-editable source of attachment exclusion rules and is combined with `.gitignore`.

Attaching files creates conversation attachments representing that scan. It does not give ChatGPT an ongoing filesystem tool, so changed files must be attached again when fresh contents are needed.

## Troubleshooting

If controls are missing, keep `c2c` running in the foreground and confirm the desktop app was launched with a CDP debug port. If attachments appear in the wrong composer, open the intended Quick Chat first and retry. Stop `c2c` with Ctrl-C to remove the injected UI.
