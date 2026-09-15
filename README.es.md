# Codex with ChatGPT · Swift para macOS

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md) | [Français](README.fr.md) | **Español** | [日本語](README.ja.md) | [한국어](README.ko.md)

Una app para macOS que hace más fluido el trabajo entre Codex y ChatGPT Quick Chat.

El flujo habitual empieza con una conversación en Quick Chat y continúa con «Añadir a Codex» cuando llega el momento de implementar. Como ChatGPT y Codex son sistemas distintos, volver más tarde a esa conversación suele implicar buscarla manualmente. Esta app añade un botón junto a cada sesión de Codex: el primer clic abre Quick Chat y los siguientes vuelven a la misma conversación.

Cuando ChatGPT necesita el contexto del proyecto, también puedes adjuntar desde el mismo menú los archivos del directorio de trabajo de esa sesión. Los conjuntos grandes se dividen automáticamente en lotes y los archivos sensibles se pueden excluir mediante `.c2cignore`. Los botones se inyectan al abrir la app; si no los usas, el funcionamiento normal de Codex y ChatGPT no cambia.

![Acciones de Quick Chat, archivos del proyecto y reglas de exclusión para una sesión de Codex](docs/images/session-quick-chat-actions.png)

**Requiere macOS 13 o posterior. Compatible con Apple Silicon e Intel. No requiere Node.js ni npm.** La app y la CLI interactúan con la interfaz de escritorio localmente mediante CDP. No inician ningún servidor HTTP, flujo OAuth, servicio MCP, túnel ni conexión pública. Sparkle 2 proporciona actualizaciones automáticas firmadas.

## Descarga e instalación

Versión actual: **v0.1.2**

- [Descargar para Apple Silicon (M1/M2/M3/M4)](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [Descargar para Intel](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [Ver la última versión y el registro de cambios](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

Abre el DMG, arrastra `CodexWithChatGPT.app` a `/Applications` y ejecuta la app. Está firmada con Developer ID y notarizada por Apple. Las próximas versiones estarán disponibles mediante el actualizador Sparkle integrado.

## Uso

1. Abre Codex y después ejecuta `CodexWithChatGPT.app`. La app permanece en la barra de menús y añade automáticamente botones de acción a las sesiones.
2. Haz clic en el icono situado a la derecha de cualquier sesión de Codex.
3. Elige una acción:
   - **Abrir／continuar Quick Chat**: crea una conversación la primera vez y vuelve a esa misma conversación después.
   - **Adjuntar archivos del proyecto**: adjunta a Quick Chat los archivos de código fuente y texto del directorio de trabajo de la sesión.
   - **Editar reglas de exclusión**: abre el archivo `.c2cignore` del proyecto para controlar qué archivos nunca deben adjuntarse.

Cuando Quick Chat esté vinculado, haz clic en la «×» junto a la sesión para desvincularlo. Si hay más de 20 archivos, se dividirán automáticamente en lotes. Envía el mensaje actual y vuelve a elegir «Adjuntar archivos del proyecto» para cargar el siguiente lote.

Si los botones no aparecen, selecciona «Volver a inyectar» en la app de la barra de menús.

## Límites de seguridad de los archivos adjuntos

- No inicia ningún servidor HTTP, flujo OAuth, servicio MCP, túnel ni puerto de escucha público.
- Solo examina el directorio de trabajo de la sesión; nunca adjunta archivos externos ni enlaces simbólicos.
- `.c2cignore` contiene exclusiones de seguridad visibles y editables; también se aplica `.gitignore`.
- Cada lote admite como máximo 20 archivos y 8 MiB. Cada archivo está limitado a 1 MiB y debe ser texto UTF-8 válido.
- Los archivos adjuntos contienen el contenido existente en el momento del clic. No proporcionan a ChatGPT acceso continuo al proyecto local.

El [skill de operación](skill/SKILL.md) incluido ofrece un flujo de trabajo para Swift/macOS y no se instala automáticamente en tu configuración personal de Codex.

## Licencia

Este proyecto se distribuye bajo la [licencia MIT](LICENSE) y no es un producto oficial de OpenAI.
