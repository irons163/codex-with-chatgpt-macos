---
name: codex-with-chatgpt-macos
description: Use the native macOS Swift c2c bridge to connect a local workspace to ChatGPT for planning and review while Codex retains execution. Applies to setup, connection repair, disconnection, and tasks explicitly using the ChatGPT planning loop.
---

# Codex with ChatGPT for macOS

Use the Swift `c2c` CLI from this checkout. The bridge exposes nine read-only MCP tools; Codex owns edits, commands, git and tests. ChatGPT reads required source and execution evidence through MCP.

## Locate and build

The macOS checkout lives at: `/Volumes/M2SSD/Documents/codex-with-chatgpt-macos`.
When installing this skill elsewhere, update that line to the actual checkout.

Use `<checkout>/dist/c2c`; if absent, run `<checkout>/scripts/build.sh`. This is a macOS 13+ Swift package, requiring Swift 5.9+ to build. Do not run Node, npm or pnpm to build the bridge. Keep target workspace explicit with `--workspace <path>`; do not accidentally expose the bridge's own checkout.

State is in `~/Library/Application Support/codex-with-chatgpt-macos` unless `C2C_STATE_DIR` overrides it. It is independent of the TypeScript edition and requires fresh pairing. Never copy a live daemon's runtime or credentials between editions.

## Connect and diagnose

1. Inspect `c2c status --workspace <path> --json` and `c2c prefs get --json`.
2. On first connection, use the saved `setupMode` (auto/manual) or obtain the user's preference if absent. `prefs set --setup-mode auto|manual --json` saves the choice. Preserve an explicit browser preference from the user; otherwise use an available in-app browser.
3. Run `c2c setup --workspace <path> --json`. It starts a loopback-only daemon and emits a local `mcpUrl`, `pairingCode` and expiry. The MCP URL is usable only by clients on the same Mac; there is no public connection mode.
4. Prefer `c2c entry --workspace <path>` for the Codex/ChatGPT desktop workflow. It injects the workspace attachment and per-session Quick Chat controls over CDP without MCP setup.
5. Save `prefs set --developer-mode --json` only after developer mode is confirmed enabled. For a local MCP client, confirm it can invoke `workspace_info` and read an allowed file before declaring the connection verified.

Use `doctor --json` for repair, or `doctor --no-fix --json` for observation. Inspect `report.bridge` and `report.mcp`. Unknown bridge identity is not a stopped bridge: do not force-kill its PID or start another copy.

`setup`, `doctor` with fixes, and `sandbox-allow` maintain the state directory entry in Codex's writable roots. Do not change unrelated sandbox or approval settings. To disconnect, use `unpair` to revoke access and `stop` to stop the local bridge.

## Planning and independent review

Keep messages to ChatGPT below about 1 KB. Send goal, task ID, iteration and state; never paste source files, diffs, logs or credentials. Ask ChatGPT to use the workspace tools to inspect details.

The loop is `INIT → PLAN → EXECUTED → REVIEW → DONE`. Apply an authorized plan locally, run appropriate checks, then save evidence:

```sh
c2c record --workspace <path> --task <id> --iteration <n> \
  --changed-files <count-or-comma-separated-paths> --tests '<summary>' \
  --exit-status ok --command 'swift test' --output-file <local-log> --exit-code 0
```

The output is available only for allowlisted commands and is sanitized by the bridge. `--command` labels evidence; it does not run the command. Never claim tests passed without real execution. ChatGPT reviews actual `git_diff`, `test_status`, `execution_summary` and `execution_output` evidence through MCP. Continue fixes until the requested outcome is verified or a real dependency needs the user.

## Conversation and checkpoints

`session get --json` returns the saved session and resolved conversation mode. New workspaces default to `project`; a legacy conversation retains `long-chat`. Save the actual observed ChatGPT URLs with `session set --mode project --project-url <url> --url <chat-url>`, or `--mode long-chat --url <chat-url>`. In project mode, begin a new Codex task's chat inside the saved ChatGPT Project. Reuse the current task's saved chat when resuming.

Before a handoff, use `session set --task <id> --iteration <n> --protocol-state <state> --waiting-for <who> --goal '<goal>' --completed-subtasks '<done>' --known-issues '<issues>' --next-step '<next>'`. Run `c2c --help` and inspect validation errors for accepted values. `session clear` clears the chat pointer while retaining a Project binding; `--clear-checkpoint` clears only the active checkpoint.

## Updates

`update-check --json` checks only this Swift checkout's configured git upstream. Do not replace this package with the original TypeScript repository. For an explicitly requested update, inspect local changes, fetch/fast-forward the configured Swift branch when appropriate, run `swift test`, rebuild with `scripts/build.sh`, and preserve the user's edits and settings. A missing upstream is a reported limitation, not permission to invent one.
