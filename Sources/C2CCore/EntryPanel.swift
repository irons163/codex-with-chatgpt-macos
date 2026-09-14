import Foundation

public enum EntryPanel {
    public static let marker = "__c2cWorkspaceReaderInstalled"
    public static let version = "workspace-attachments-v12"
    public static let bindingName = "c2cWorkspaceReader"
    public static let resultFunction = "__c2cEntryResult"
    public static let hostID = "c2c-entry-host"
    public static let quickChatCleanupFunction = "__c2cQuickChatCleanup"
    public static let quickChatStorageKey = "c2c.quick-chat-by-thread.v1"

    public static var presenceScript: String {
        "window[\"\(marker)\"] === \"\(version)\" && document.getElementById(\"\(hostID)\") !== null"
    }

    static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    public static func installScript(workspaceName: String) -> String {
        let workspace = jsonLiteral(workspaceName)
        return """
        (function () {
          var MARKER = "\(marker)";
          var VERSION = "\(version)";
          var BINDING = "\(bindingName)";
          var RESULT = "\(resultFunction)";
          var QUICK_CHAT_CLEANUP = "\(quickChatCleanupFunction)";
          var QUICK_CHAT_STORAGE = "\(quickChatStorageKey)";
          var previousHost = document.getElementById("\(hostID)");
          if (window[MARKER] === VERSION && previousHost) return "already";
          if (typeof window[QUICK_CHAT_CLEANUP] === "function") {
            try { window[QUICK_CHAT_CLEANUP](); } catch (error) {}
          }
          if (previousHost) previousHost.remove();
          window[MARKER] = VERSION;
          var WORKSPACE = \(workspace);
          var host = document.createElement("div");
          host.id = "\(hostID)";
          host.style.cssText = "position:fixed;right:18px;bottom:110px;width:0;height:0;z-index:2147483647;";
          var shadow = host.attachShadow({ mode: "closed" });
          var style = document.createElement("style");
          style.textContent = [
            ":host{all:initial}",
            "*{box-sizing:border-box;font-family:-apple-system,'SF Pro Text','Helvetica Neue',sans-serif}",
            ".bubble{position:absolute;left:0;top:0;width:40px;height:40px;border-radius:50%;cursor:pointer;user-select:none;-webkit-user-select:none;background:rgba(20,20,22,0.85);border:1px solid rgba(255,255,255,0.25);color:#fff;display:flex;align-items:center;justify-content:center;box-shadow:0 4px 14px rgba(0,0,0,0.4);backdrop-filter:blur(6px)}",
            ".bubble:hover{background:rgba(48,48,52,0.9)}",
            ".bubble svg{width:20px;height:20px;fill:#fff;pointer-events:none}",
            ".panel{position:absolute;right:0;bottom:48px;width:252px;padding:10px;border-radius:10px;background:rgba(18,18,20,0.96);border:1px solid rgba(255,255,255,0.14);box-shadow:0 8px 28px rgba(0,0,0,0.5);display:none}",
            ".panel.open{display:block}",
            ".panel h1{margin:0 0 2px;font-size:12px;font-weight:600;color:#eee;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
            ".panel p{margin:0 0 8px;font-size:10px;color:#888}",
            ".panel button{display:block;width:100%;margin:0 0 6px;padding:8px 10px;border-radius:6px;border:1px solid rgba(255,255,255,0.16);background:rgba(255,255,255,0.08);color:#eee;font-size:12px;text-align:left;cursor:pointer}",
            ".panel button:hover{background:rgba(255,255,255,0.16)}",
            ".status{min-height:14px;margin:2px 0 0;font-size:10px;color:#9be29b}",
            ".toast{position:absolute;right:0;bottom:92px;width:252px;padding:8px 10px;border-radius:8px;background:rgba(18,18,20,0.96);border:1px solid rgba(255,255,255,0.14);color:#ddd;font-size:11px;line-height:1.4;display:none}",
            ".toast.show{display:block}"
          ].join("");
          shadow.appendChild(style);
          var bubble = document.createElement("div");
          bubble.className = "bubble";
          bubble.title = "ChatGPT 工作目錄附件";
          bubble.innerHTML = '<svg viewBox="0 0 24 24"><path d="M10 4l2 2h8a2 2 0 012 2v9a3 3 0 01-3 3H5a3 3 0 01-3-3V7a3 3 0 013-3h5zm-5 4v9a1 1 0 001 1h13a1 1 0 001-1V8H5z"/></svg>';
          var panel = document.createElement("div");
          panel.className = "panel";
          var heading = document.createElement("h1");
          heading.textContent = "ChatGPT 工作目錄附件";
          var hint = document.createElement("p");
          hint.textContent = "工作區：" + WORKSPACE;
          var chooseButton = document.createElement("button");
          chooseButton.textContent = "選擇工作目錄…";
          var attachButton = document.createElement("button");
          attachButton.textContent = "附加目前專案檔案";
          var status = document.createElement("div");
          status.className = "status";
          var toast = document.createElement("div");
          toast.className = "toast";
          panel.appendChild(heading);
          panel.appendChild(hint);
          panel.appendChild(chooseButton);
          panel.appendChild(attachButton);
          panel.appendChild(status);
          shadow.appendChild(bubble);
          shadow.appendChild(panel);
          shadow.appendChild(toast);
          document.documentElement.appendChild(host);
          var quickChatStyle = document.createElement("style");
          quickChatStyle.id = "c2c-session-quick-chat-style";
          quickChatStyle.textContent = [
            "[data-app-action-sidebar-thread-row]>[data-c2c-quick-chat-button],[data-app-action-sidebar-thread-row]>[data-c2c-quick-chat-unbind-button]{appearance:none;border:0;background:transparent;color:var(--color-text-tertiary,currentColor);display:flex;align-items:center;justify-content:center;position:absolute;top:50%;transform:translateY(-50%);z-index:20;width:20px;height:20px;padding:0;border-radius:5px;cursor:pointer}",
            "[data-app-action-sidebar-thread-row][data-c2c-quick-chat-state=unbound]{padding-inline-end:82px}",
            "[data-app-action-sidebar-thread-row][data-c2c-quick-chat-state=bound]{padding-inline-end:106px}",
            "[data-app-action-sidebar-thread-row]>[data-c2c-quick-chat-button]{inset-inline-end:58px}",
            "[data-app-action-sidebar-thread-row]>[data-c2c-quick-chat-unbind-button]{inset-inline-end:82px;width:18px;height:18px}",
            "[data-c2c-quick-chat-button]:hover,[data-c2c-quick-chat-unbind-button]:hover{color:var(--color-text,currentColor);background:var(--color-background-primary-ghost-hover,rgba(127,127,127,.14))}",
            "[data-c2c-quick-chat-button]:focus-visible,[data-c2c-quick-chat-unbind-button]:focus-visible{outline:2px solid var(--color-ring,currentColor);outline-offset:0}",
            "[data-c2c-quick-chat-button] svg{width:16px;height:16px;pointer-events:none}",
            "[data-c2c-quick-chat-unbind-button] svg{width:12px;height:12px;pointer-events:none}",
            "[data-c2c-quick-chat-button][data-c2c-has-chat=true]{color:var(--color-text,currentColor)}"
          ].join("");
          document.head.appendChild(quickChatStyle);
          var quickChatBindings = {};
          try {
            var storedQuickChats = JSON.parse(localStorage.getItem(QUICK_CHAT_STORAGE) || "{}");
            if (storedQuickChats && typeof storedQuickChats === "object" && !Array.isArray(storedQuickChats)) {
              Object.keys(storedQuickChats).forEach(function (threadID) {
                var conversationID = String(storedQuickChats[threadID] || "").replace(/^chatgpt:/, "");
                if (conversationID && conversationID.indexOf("local-chatgpt:") !== 0) {
                  quickChatBindings[threadID] = conversationID;
                }
              });
            }
          } catch (error) {}
          var activeQuickChatThreadID = null;
          var openingQuickChat = false;
          var quickChatWasOpen = false;
          var quickChatDisposed = false;
          var quickChatScanScheduled = false;
          var quickChatScanFrame = 0;
          function saveQuickChatBindings() {
            try { localStorage.setItem(QUICK_CHAT_STORAGE, JSON.stringify(quickChatBindings)); } catch (error) {}
          }
          function normalizeQuickChatID(value) {
            return String(value || "").replace(/^chatgpt:/, "");
          }
          function unbindQuickChat(threadID) {
            if (!threadID || !quickChatBindings[threadID]) return;
            delete quickChatBindings[threadID];
            if (activeQuickChatThreadID === threadID) activeQuickChatThreadID = null;
            saveQuickChatBindings();
            scheduleQuickChatScan();
            showToast("已解除 Quick Chat 綁定");
          }
          function quickChatPanel() {
            return document.querySelector('section[data-pip-obstacle="quick-chat"][data-state="open"]');
          }
          function currentQuickChatID(panel) {
            var context = panel && panel.querySelector("[data-above-composer-conversation-id]");
            return normalizeQuickChatID(context && context.getAttribute("data-above-composer-conversation-id"));
          }
          function nativeQuickChatButton() {
            return Array.from(document.querySelectorAll("button")).find(function (button) {
              if (button.hasAttribute("data-c2c-quick-chat-button")) return false;
              var label = (button.getAttribute("aria-label") || "").toLowerCase();
              return label === "快速對話" || label === "快速聊天" || label === "quick chat";
            }) || null;
          }
          function waitForQuickChat(test, timeout) {
            return new Promise(function (resolve) {
              var started = Date.now();
              function check() {
                var result = null;
                try { result = test(); } catch (error) {}
                if (result || Date.now() - started >= timeout) resolve(result);
                else setTimeout(check, 40);
              }
              check();
            });
          }
          function reactFiber(element) {
            if (!element) return null;
            var key = Object.keys(element).find(function (name) { return name.indexOf("__reactFiber$") === 0; });
            return key ? element[key] : null;
          }
          function renderedConversationButton(panel, conversationID) {
            return Array.from(panel.querySelectorAll("li button")).find(function (button) {
              var fiber = reactFiber(button);
              for (var depth = 0; fiber && depth < 5; depth++, fiber = fiber.return) {
                if (String(fiber.key || "") === conversationID) return true;
              }
              return false;
            }) || null;
          }
          function selectQuickChatConversation(panel, conversationID, fallbackTitle) {
            var rendered = renderedConversationButton(panel, conversationID);
            if (rendered) { rendered.click(); return true; }
            var recent = panel.querySelector('section[aria-labelledby="quick-chat-recent-heading"]');
            var fiber = reactFiber(recent || panel.querySelector("[data-thread-find-composer]"));
            var selectionProps = null;
            for (var depth = 0; fiber && depth < 30; depth++, fiber = fiber.return) {
              var props = fiber.memoizedProps;
              if (!props || !Array.isArray(props.conversations) || typeof props.onConversationSelect !== "function") continue;
              selectionProps = props;
              var conversation = props.conversations.find(function (item) {
                return normalizeQuickChatID(item && item.conversationId) === conversationID;
              });
              if (!conversation) continue;
              props.onConversationSelect(conversation.conversationId, conversation.title || fallbackTitle);
              return true;
            }
            if (!selectionProps) return false;
            // Quick Chat's native handler accepts (conversationID, title). It can
            // restore a conversation that is not part of the three rendered recents.
            selectionProps.onConversationSelect(conversationID, fallbackTitle);
            return true;
          }
          function setQuickChatBinding(threadID, conversationID) {
            conversationID = normalizeQuickChatID(conversationID);
            if (!threadID || !conversationID) return;
            if (conversationID.indexOf("local-chatgpt:") === 0) return;
            var changed = normalizeQuickChatID(quickChatBindings[threadID]) !== conversationID;
            Object.keys(quickChatBindings).forEach(function (otherThreadID) {
              if (otherThreadID !== threadID && normalizeQuickChatID(quickChatBindings[otherThreadID]) === conversationID) {
                delete quickChatBindings[otherThreadID];
                changed = true;
              }
            });
            if (!changed) return;
            quickChatBindings[threadID] = conversationID;
            saveQuickChatBindings();
            scheduleQuickChatScan();
          }
          function captureActiveQuickChat() {
            var panel = quickChatPanel();
            if (panel) {
              quickChatWasOpen = true;
              if (activeQuickChatThreadID) {
                var conversationID = currentQuickChatID(panel);
                if (conversationID) setQuickChatBinding(activeQuickChatThreadID, conversationID);
              }
            } else if (quickChatWasOpen && !openingQuickChat) {
              quickChatWasOpen = false;
              activeQuickChatThreadID = null;
            }
          }
          function newQuickChatButton(panel) {
            return Array.from(panel.querySelectorAll("button")).find(function (button) {
              var label = (button.getAttribute("aria-label") || "").toLowerCase();
              return label === "新對話" || label === "new chat";
            }) || null;
          }
          async function openQuickChatForThread(row) {
            if (openingQuickChat) return;
            openingQuickChat = true;
            var threadID = row.getAttribute("data-app-action-sidebar-thread-id") || "";
            var previousActiveThreadID = activeQuickChatThreadID;
            try {
              if (row.getAttribute("data-app-action-sidebar-thread-selected") !== "true") {
                row.click();
                await waitForQuickChat(function () {
                  return row.getAttribute("data-app-action-sidebar-thread-selected") === "true";
                }, 2000);
              }
              activeQuickChatThreadID = threadID;
              var panel = quickChatPanel();
              if (!panel) {
                var nativeButton = nativeQuickChatButton();
                if (!nativeButton) throw new Error("找不到內建 Quick Chat 入口");
                nativeButton.click();
                panel = await waitForQuickChat(quickChatPanel, 2500);
              }
              if (!panel) throw new Error("Quick Chat 未開啟");

              var mappedID = normalizeQuickChatID(quickChatBindings[threadID]);
              var currentID = currentQuickChatID(panel);
              if (mappedID && currentID !== mappedID) {
                var createButton = newQuickChatButton(panel);
                if (createButton) {
                  createButton.click();
                  await waitForQuickChat(function () {
                    var nextPanel = quickChatPanel();
                    return nextPanel && currentQuickChatID(nextPanel) !== currentID ? nextPanel : null;
                  }, 2000);
                  panel = quickChatPanel() || panel;
                }
                var threadTitle = row.getAttribute("data-app-action-sidebar-thread-title") || "Quick Chat";
                if (!selectQuickChatConversation(panel, mappedID, threadTitle)) {
                  throw new Error("找不到 Quick Chat 的對話切換功能");
                }
                var resumed = await waitForQuickChat(function () {
                  return currentQuickChatID(quickChatPanel()) === mappedID;
                }, 4000);
                if (!resumed) {
                  throw new Error("無法繼續這個 session 原本的 Quick Chat 對話");
                }
              }

              if (!mappedID) {
                panel = quickChatPanel() || panel;
                currentID = currentQuickChatID(panel);
                if (currentID.indexOf("local-chatgpt:") !== 0 ||
                    (previousActiveThreadID && previousActiveThreadID !== threadID)) {
                  var newButton = newQuickChatButton(panel);
                  if (!newButton) throw new Error("找不到 Quick Chat 的新對話按鈕");
                  newButton.click();
                  await waitForQuickChat(function () {
                    var nextID = currentQuickChatID(quickChatPanel());
                    return nextID && nextID !== currentID ? nextID : null;
                  }, 2500);
                }
              }
              panel = quickChatPanel() || panel;
              setQuickChatBinding(threadID, currentQuickChatID(panel));
              var editor = panel.querySelector('[contenteditable="true"][role="textbox"], textarea[role="textbox"]');
              if (editor) editor.focus();
            } catch (error) {
              console.warn("c2c Quick Chat:", error);
              showToast(error && error.message ? error.message : "Quick Chat 開啟失敗");
            } finally {
              openingQuickChat = false;
              captureActiveQuickChat();
              scheduleQuickChatScan();
            }
          }
          function quickChatIcon() {
            return '<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16"><path d="M7.983 5.304a.526.526 0 01.526.526v1.649h1.649a.525.525 0 110 1.051H8.509v1.65a.526.526 0 01-1.051 0V8.53h-1.65a.525.525 0 110-1.051h1.65V5.83a.526.526 0 01.525-.526z" fill="currentColor"/><path fill-rule="evenodd" d="M8 1.808c3.575 0 6.525 2.745 6.525 6.192 0 3.448-2.95 6.192-6.525 6.192-1.215 0-2.241-.363-3.245-.832l-1.768.459a.66.66 0 01-.807-.78l.37-1.675C2.036 10.36 1.475 9.382 1.475 8 1.475 4.553 4.425 1.808 8 1.808zm0 1.051C4.948 2.859 2.525 5.189 2.525 8c0 1.134.455 1.883 1.027 3.015a.65.65 0 01.054.44l-.263 1.186 1.283-.332a.65.65 0 01.45.043l.366.17c.85.378 1.65.62 2.558.62 3.052 0 5.474-2.33 5.475-5.142 0-2.811-2.423-5.141-5.475-5.141z" fill="currentColor"/></svg>';
          }
          function unbindQuickChatIcon() {
            return '<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16"><path d="M4.25 4.25l7.5 7.5m0-7.5l-7.5 7.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
          }
          function installQuickChatButton(row) {
            var threadID = row.getAttribute("data-app-action-sidebar-thread-id");
            if (!threadID) return;
            var button = row.querySelector(':scope > [data-c2c-quick-chat-button="true"]');
            if (!button) {
              button = document.createElement("button");
              button.type = "button";
              button.setAttribute("data-c2c-quick-chat-button", "true");
              button.innerHTML = quickChatIcon();
              button.addEventListener("click", function (event) {
                event.preventDefault();
                event.stopPropagation();
                event.stopImmediatePropagation();
                openQuickChatForThread(row);
              });
              row.appendChild(button);
            }
            var title = row.getAttribute("data-app-action-sidebar-thread-title") || "這個 session";
            var hasChat = !!quickChatBindings[threadID];
            row.setAttribute("data-c2c-quick-chat-state", hasChat ? "bound" : "unbound");
            button.setAttribute("data-c2c-has-chat", hasChat ? "true" : "false");
            button.setAttribute("aria-label", (hasChat ? "繼續「" : "為「") + title + (hasChat ? "」的快速對話" : "」開啟快速對話"));
            button.title = button.getAttribute("aria-label");
            var unbindButton = row.querySelector(':scope > [data-c2c-quick-chat-unbind-button="true"]');
            if (hasChat && !unbindButton) {
              unbindButton = document.createElement("button");
              unbindButton.type = "button";
              unbindButton.setAttribute("data-c2c-quick-chat-unbind-button", "true");
              unbindButton.innerHTML = unbindQuickChatIcon();
              unbindButton.addEventListener("click", function (event) {
                event.preventDefault();
                event.stopPropagation();
                event.stopImmediatePropagation();
                unbindQuickChat(threadID);
              });
              row.appendChild(unbindButton);
            } else if (!hasChat && unbindButton) {
              unbindButton.remove();
              unbindButton = null;
            }
            if (unbindButton) {
              unbindButton.setAttribute("aria-label", "解除「" + title + "」的 Quick Chat 綁定");
              unbindButton.title = unbindButton.getAttribute("aria-label");
            }
          }
          function scanQuickChatRows() {
            document.querySelectorAll("[data-app-action-sidebar-thread-row][data-app-action-sidebar-thread-id]").forEach(installQuickChatButton);
            captureActiveQuickChat();
          }
          function scheduleQuickChatScan() {
            if (quickChatDisposed || quickChatScanScheduled) return;
            quickChatScanScheduled = true;
            quickChatScanFrame = requestAnimationFrame(function () {
              quickChatScanFrame = 0;
              quickChatScanScheduled = false;
              if (quickChatDisposed) return;
              scanQuickChatRows();
            });
          }
          var quickChatObserver = new MutationObserver(scheduleQuickChatScan);
          quickChatObserver.observe(document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ["data-above-composer-conversation-id", "data-app-action-sidebar-thread-selected"]
          });
          window[QUICK_CHAT_CLEANUP] = function () {
            quickChatDisposed = true;
            quickChatObserver.disconnect();
            if (quickChatScanFrame) cancelAnimationFrame(quickChatScanFrame);
            quickChatScanFrame = 0;
            quickChatScanScheduled = false;
            document.querySelectorAll('[data-c2c-quick-chat-button="true"]').forEach(function (button) { button.remove(); });
            document.querySelectorAll('[data-c2c-quick-chat-unbind-button="true"]').forEach(function (button) { button.remove(); });
            document.querySelectorAll('[data-c2c-quick-chat-state]').forEach(function (row) { row.removeAttribute("data-c2c-quick-chat-state"); });
            quickChatStyle.remove();
            try { delete window[QUICK_CHAT_CLEANUP]; } catch (error) { window[QUICK_CHAT_CLEANUP] = undefined; }
          };
          scanQuickChatRows();
          var toastTimer = 0;
          function showToast(message) {
            toast.textContent = message;
            toast.classList.add("show");
            clearTimeout(toastTimer);
            toastTimer = setTimeout(function () { toast.classList.remove("show"); }, 4000);
          }
          function setStatus(message) { status.textContent = message; }
          function setBusy(busy) {
            chooseButton.disabled = busy;
            attachButton.disabled = busy;
          }
          function updateQueueState(payload) {
            WORKSPACE = payload.workspace || WORKSPACE;
            hint.textContent = "工作區：" + WORKSPACE;
            if (payload.hasPendingBatch === true) {
              attachButton.textContent = "送出後附加下一批（剩 " + (payload.remainingCount || 0) + " 個）";
            } else {
              attachButton.textContent = "附加目前專案檔案";
            }
          }
          function callNative(action, silent) {
            if (typeof window[BINDING] !== "function") {
              showToast("工作目錄連線尚未就緒，請確認 c2c 仍在執行。");
              return;
            }
            setBusy(true);
            if (!silent) setStatus("處理中…");
            try { window[BINDING](JSON.stringify({ action: action })); }
            catch (error) { setBusy(false); setStatus(""); showToast("無法呼叫 c2c：" + error); }
          }
          chooseButton.addEventListener("click", function () { callNative("choose-workspace"); });
          attachButton.addEventListener("click", function () { callNative("attach-workspace-files"); });
          window[RESULT] = function (payloadText) {
            var payload = null;
            try { payload = JSON.parse(String(payloadText)); } catch (error) {}
            setBusy(false);
            if (!payload || typeof payload !== "object") { setStatus(""); showToast("c2c 回應無法解析。"); return; }
            if (payload.ok === true) {
              if (payload.action === "state") {
                updateQueueState(payload);
              } else if (payload.action === "choose-workspace") {
                WORKSPACE = payload.workspace || WORKSPACE;
                hint.textContent = "工作區：" + WORKSPACE;
                attachButton.textContent = "附加目前專案檔案";
                setStatus("已選擇工作目錄");
                showToast("工作目錄已切換為「" + WORKSPACE + "」。");
              } else if (payload.action === "attach-workspace-files") {
                var count = payload.count || 0;
                var batchNumber = payload.batchNumber || 1;
                var batchCount = payload.batchCount || 1;
                var remainingCount = payload.remainingCount || 0;
                setStatus("已附加第 " + batchNumber + "/" + batchCount + " 批（" + count + " 個）");
                if (payload.hasMore === true) {
                  attachButton.textContent = "送出後附加下一批（剩 " + remainingCount + " 個）";
                  showToast("第 " + batchNumber + "/" + batchCount + " 批已附加。請先送出這則訊息，再按下一批。" +
                    (payload.incomplete === true ? " 部分檔案因無法安全讀取而未列入。" : ""));
                } else {
                  attachButton.textContent = batchCount > 1 ? "從第一批重新開始" : "重新附加目前專案檔案";
                  showToast(payload.incomplete === true
                    ? "可安全讀取的批次已完成；部分檔案未列入。"
                    : "第 " + batchNumber + "/" + batchCount + " 批已附加；全部批次完成。");
                }
              }
            } else if (payload.cancelled === true) {
              setStatus(""); showToast("已取消。");
            } else {
              setStatus(""); showToast(payload.error || "讀取工作目錄失敗。");
            }
          };
          callNative("get-state", true);
          var drag = null;
          bubble.addEventListener("pointerdown", function (event) {
            if (event.button !== 0) return;
            drag = { startX: event.clientX, startY: event.clientY, moved: false, rect: bubble.getBoundingClientRect() };
            try { bubble.setPointerCapture(event.pointerId); } catch (error) {}
            event.preventDefault();
          });
          bubble.addEventListener("pointermove", function (event) {
            if (!drag) return;
            var dx = event.clientX - drag.startX, dy = event.clientY - drag.startY;
            if (Math.abs(dx) + Math.abs(dy) < 5) return;
            if (!drag.moved) {
              drag.moved = true;
              host.style.right = "auto"; host.style.bottom = "auto";
              var current = bubble.getBoundingClientRect();
              host.style.left = current.left + "px"; host.style.top = current.top + "px";
            }
            var left = Math.min(Math.max(drag.rect.left + dx, 4), window.innerWidth - drag.rect.width - 4);
            var top = Math.min(Math.max(drag.rect.top + dy, 4), window.innerHeight - drag.rect.height - 4);
            host.style.left = left + "px"; host.style.top = top + "px";
          });
          bubble.addEventListener("pointerup", function () {
            if (!drag) return;
            var moved = drag.moved;
            drag = null;
            if (!moved) panel.classList.toggle("open");
          });
          bubble.addEventListener("pointercancel", function () { drag = null; });
          return "installed";
        })();
        """
    }

    public static let clearScript = """
        (function () {
          var cleanup = window["\(quickChatCleanupFunction)"];
          if (typeof cleanup === "function") { try { cleanup(); } catch (error) {} }
          var host = document.getElementById("\(hostID)");
          if (host && host.parentNode) host.parentNode.removeChild(host);
          try { delete window.\(marker); } catch (error) { window.\(marker) = undefined; }
          try { delete window.\(resultFunction); } catch (error) { window.\(resultFunction) = undefined; }
        })();
        """
}
