# Codex with ChatGPT · Swift for macOS

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | **日本語** | [한국어](README.ko.md)

Codex と ChatGPT Quick Chat の行き来をスムーズにする macOS アプリです。

一般的な流れは、まず Quick Chat で相談し、実装する段階で「Codex に追加」を選ぶというものです。ただし ChatGPT と Codex は別のシステムなので、あとで同じ会話に戻るには自分で探し直す必要があります。このアプリは各 Codex session の横に操作ボタンを追加します。最初のクリックで Quick Chat を開き、次回以降は同じ会話に戻れます。

ChatGPT にプロジェクトの内容を見せたい場合は、同じメニューからその session の作業ディレクトリにあるファイルを添付できます。ファイルが多い場合は自動的に分割され、機密ファイルは `.c2cignore` で除外できます。アプリを起動するとボタンが自動的に挿入されます。ボタンを使わない限り、通常の Codex／ChatGPT の操作には影響しません。

![Codex session の Quick Chat、プロジェクト添付、除外ルールの操作メニュー](docs/images/session-quick-chat-actions.png)

**macOS 13 以降が必要です。Apple Silicon と Intel に対応。Node.js と npm は不要です。** アプリと CLI は CDP を使い、デスクトップ UI をローカルで操作します。HTTP server、OAuth、MCP、tunnel、外部公開接続は起動しません。署名済みアプリの自動更新には Sparkle 2 を使用します。

## ダウンロードとインストール

現在のバージョン：**v0.1.2**

- [Apple Silicon 版をダウンロード（M1／M2／M3／M4）](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [Intel 版をダウンロード](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [最新リリースと変更履歴を見る](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

DMG を開き、`CodexWithChatGPT.app` を `/Applications` にドラッグして起動してください。アプリは Developer ID で署名され、Apple の notarization も完了しています。以降の更新は内蔵の Sparkle updater から入手できます。

## 使い方

1. Codex を開き、`CodexWithChatGPT.app` を起動します。アプリはメニューバーに常駐し、各 session に操作ボタンを自動で追加します。
2. 任意の Codex session の右側にあるアイコンをクリックします。
3. メニューから操作を選びます：
   - **Quick Chat を開く／続ける**：初回は会話を作成し、次回以降は同じ会話に戻ります。
   - **プロジェクトファイルを添付**：その session の作業ディレクトリにあるソースコードとテキストファイルを Quick Chat に添付します。
   - **除外ルールを編集**：プロジェクトの `.c2cignore` を開き、添付しないファイルを設定します。

Quick Chat を紐付けた後は、session の横にある「×」で解除できます。ファイルが 20 個を超える場合は自動的に分割されます。現在のメッセージを送信してから、もう一度「プロジェクトファイルを添付」を選ぶと次の分を読み込めます。

ボタンが表示されない場合は、メニューバーアプリから「再注入」を選んでください。

## 添付ファイルのセキュリティ境界

- HTTP server、OAuth、MCP、tunnel、外部公開 listener は起動しません。
- 対象 session の作業ディレクトリだけを走査し、ディレクトリ外のファイルやシンボリックリンクは添付しません。
- `.c2cignore` には確認・編集可能な標準の安全除外ルールがまとまっており、`.gitignore` も適用されます。
- 1 バッチは最大 20 ファイル、合計 8 MiB です。1 ファイルは最大 1 MiB で、有効な UTF-8 テキストに限られます。
- 添付されるのはボタンを押した時点のファイル内容です。ChatGPT にローカルプロジェクトへの継続的なアクセス権を与えるものではありません。

同梱の[操作 skill](skill/SKILL.md)には Swift/macOS ワークフローが含まれていますが、個人の Codex 設定には自動インストールされません。

## ライセンス

このプロジェクトは [MIT License](LICENSE) で公開されており、OpenAI の公式製品ではありません。
