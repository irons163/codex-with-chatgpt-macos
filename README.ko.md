# Codex with ChatGPT · Swift for macOS

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md) | [Français](README.fr.md) | [Español](README.es.md) | [日本語](README.ja.md) | **한국어**

Codex와 ChatGPT Quick Chat을 더 매끄럽게 연결해 주는 macOS 앱입니다.

일반적인 흐름은 먼저 Quick Chat에서 논의한 뒤, 구현할 때 “Codex에 추가”를 선택하는 방식입니다. 하지만 ChatGPT와 Codex는 서로 다른 시스템이므로 나중에 같은 대화로 돌아가려면 직접 다시 찾아야 합니다. 이 앱은 각 Codex session 옆에 작업 버튼을 추가합니다. 처음 누르면 Quick Chat이 열리고, 이후 다시 누르면 같은 대화로 돌아갑니다.

ChatGPT에 프로젝트 내용을 보여 주고 싶을 때는 같은 메뉴에서 해당 session의 작업 디렉터리 파일을 첨부할 수 있습니다. 파일이 많으면 자동으로 여러 배치로 나뉘며, 민감한 파일은 `.c2cignore`로 제외할 수 있습니다. 앱을 실행하면 버튼이 자동으로 주입됩니다. 버튼을 사용하지 않을 때는 기존 Codex／ChatGPT 사용 방식에 영향을 주지 않습니다.

![Codex session의 Quick Chat, 프로젝트 첨부 및 제외 규칙 작업 메뉴](docs/images/session-quick-chat-actions.png)

**macOS 13 이상이 필요하며 Apple Silicon과 Intel을 지원합니다. Node.js와 npm은 필요하지 않습니다.** 앱과 CLI는 CDP를 통해 데스크톱 UI를 로컬에서만 조작합니다. HTTP server, OAuth, MCP, tunnel 또는 공개 연결을 시작하지 않습니다. 서명된 앱의 자동 업데이트에는 Sparkle 2를 사용합니다.

## 다운로드 및 설치

현재 버전: **v0.1.2**

- [Apple Silicon용 다운로드（M1／M2／M3／M4）](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [Intel용 다운로드](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [최신 릴리스 및 변경 내역 보기](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

DMG를 열고 `CodexWithChatGPT.app`을 `/Applications`로 드래그한 다음 실행하세요. 앱은 Developer ID로 서명되고 Apple notarization을 완료했습니다. 이후 업데이트는 내장된 Sparkle updater에서 확인할 수 있습니다.

## 사용 방법

1. Codex를 연 다음 `CodexWithChatGPT.app`을 실행합니다. 앱은 메뉴 막대에 상주하며 session 작업 버튼을 자동으로 추가합니다.
2. Codex session 오른쪽의 아이콘을 클릭합니다.
3. 메뉴에서 원하는 작업을 선택합니다:
   - **Quick Chat 열기／계속하기**: 처음에는 대화를 만들고, 다음부터는 같은 대화로 돌아갑니다.
   - **프로젝트 파일 첨부**: 해당 session의 작업 디렉터리에 있는 소스 및 텍스트 파일을 Quick Chat에 첨부합니다.
   - **제외 규칙 편집**: 프로젝트의 `.c2cignore`를 열어 첨부하지 않을 파일을 설정합니다.

Quick Chat을 연결한 뒤에는 session 옆의 “×”를 눌러 연결을 해제할 수 있습니다. 파일이 20개를 넘으면 자동으로 여러 배치로 나뉩니다. 현재 메시지를 보낸 다음 “프로젝트 파일 첨부”를 다시 선택하면 다음 배치가 로드됩니다.

버튼이 나타나지 않으면 메뉴 막대 앱에서 “다시 주입”을 선택하세요.

## 첨부 파일 보안 범위

- HTTP server, OAuth, MCP, tunnel 또는 공개 listener를 시작하지 않습니다.
- 해당 session의 작업 디렉터리만 검사하며 외부 파일과 심볼릭 링크는 첨부하지 않습니다.
- `.c2cignore`에는 확인하고 수정할 수 있는 기본 보안 제외 규칙이 정리되어 있으며 `.gitignore`도 함께 적용됩니다.
- 배치당 최대 20개 파일, 총 8 MiB까지 허용됩니다. 개별 파일은 최대 1 MiB이며 유효한 UTF-8 텍스트여야 합니다.
- 첨부 파일에는 버튼을 누른 시점의 내용이 포함됩니다. ChatGPT에 로컬 프로젝트를 계속 읽을 수 있는 권한을 부여하지 않습니다.

포함된 [operation skill](skill/SKILL.md)은 Swift/macOS 워크플로를 제공하지만 개인 Codex 설정에 자동으로 설치되지는 않습니다.

## 라이선스

이 프로젝트는 [MIT License](LICENSE)로 배포되며 OpenAI의 공식 제품이 아닙니다.
