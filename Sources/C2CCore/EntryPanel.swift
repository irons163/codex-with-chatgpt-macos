import Foundation

public enum EntryPanel {
    public static let marker = "__c2cWorkspaceReaderInstalled"
    public static let version = "workspace-attachments-v18"
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
          var DEFAULT_WORKSPACE = \(workspace);
          var host = document.createElement("div");
          host.id = "\(hostID)";
          host.style.cssText = "position:fixed;right:18px;bottom:110px;width:0;height:0;z-index:2147483647;";
          var shadow = host.attachShadow({ mode: "closed" });
          var style = document.createElement("style");
          style.textContent = [
            ":host{all:initial}",
            "*{box-sizing:border-box;font-family:-apple-system,'SF Pro Text','Helvetica Neue',sans-serif}",
            ".toast{position:absolute;right:0;bottom:92px;width:252px;padding:8px 10px;border-radius:8px;background:rgba(18,18,20,0.96);border:1px solid rgba(255,255,255,0.14);color:#ddd;font-size:11px;line-height:1.4;display:none}",
            ".toast.show{display:block}"
          ].join("");
          shadow.appendChild(style);
          var toast = document.createElement("div");
          toast.className = "toast";
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
            "[data-c2c-quick-chat-button][data-c2c-has-chat=true]{color:var(--color-text,currentColor)}",
            "[data-c2c-session-menu]{position:fixed;z-index:2147483646;width:236px;padding:8px;border-radius:10px;background:var(--color-background-elevated,#202024);border:1px solid var(--color-border-default,rgba(255,255,255,.16));box-shadow:0 10px 32px rgba(0,0,0,.42);color:var(--color-text,#eee);font-family:-apple-system,'SF Pro Text','Helvetica Neue',sans-serif}",
            "[data-c2c-session-menu-title]{padding:3px 6px 1px;font-size:12px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
            "[data-c2c-session-menu-workspace]{padding:0 6px 7px;font-size:10px;color:var(--color-text-tertiary,#999);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
            "[data-c2c-session-menu] button{appearance:none;display:block;width:100%;margin:0 0 4px;padding:8px;border:0;border-radius:6px;background:transparent;color:inherit;font:inherit;font-size:12px;text-align:left;cursor:pointer}",
            "[data-c2c-session-menu] button:hover{background:var(--color-background-primary-ghost-hover,rgba(127,127,127,.16))}",
            "[data-c2c-session-menu] button:disabled{opacity:.5;cursor:default}",
            "[data-c2c-session-menu-status]{min-height:13px;padding:2px 6px 0;color:#72d68b;font-size:10px;line-height:1.3}"
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
          var quickChatCaptureTimer = 0;
          var activeQuickChatKnownConversationIDs = [];
          var sessionMenu = null;
          var sessionMenuThreadID = null;
          var sessionMenuBusy = false;
          var sessionMenuStatus = "";
          var sessionMenuWorkspace = null;
          var attachmentState = { hasPendingBatch: false, remainingCount: 0, threadID: "" };
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
          function quickChatLoadFailed(panel) {
            var text = String((panel && panel.innerText) || "").toLowerCase();
            return text.indexOf("無法載入此 chatgpt 對話") >= 0 ||
              text.indexOf("unable to load this chatgpt conversation") >= 0 ||
              text.indexOf("couldn't load this chatgpt conversation") >= 0;
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
          function quickChatConversationIDs(panel) {
            var recent = panel && panel.querySelector('section[aria-labelledby="quick-chat-recent-heading"]');
            var fiber = reactFiber(recent || (panel && panel.querySelector("[data-thread-find-composer]")));
            for (var depth = 0; fiber && depth < 30; depth++, fiber = fiber.return) {
              var props = fiber.memoizedProps;
              if (!props || !Array.isArray(props.conversations)) continue;
              return props.conversations.map(function (conversation) {
                return normalizeQuickChatID(conversation && conversation.conversationId);
              }).filter(function (conversationID) {
                return conversationID && conversationID.indexOf("local-chatgpt:") !== 0;
              });
            }
            return [];
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
            for (var depth = 0; fiber && depth < 30; depth++, fiber = fiber.return) {
              var props = fiber.memoizedProps;
              if (!props || !Array.isArray(props.conversations) || typeof props.onConversationSelect !== "function") continue;
              var conversation = props.conversations.find(function (item) {
                return normalizeQuickChatID(item && item.conversationId) === conversationID;
              });
              if (!conversation) continue;
              props.onConversationSelect(conversation.conversationId, conversation.title || fallbackTitle);
              return true;
            }
            return false;
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
                if (quickChatLoadFailed(panel)) {
                  return;
                }
                var conversationID = currentQuickChatID(panel);
                if (conversationID && conversationID.indexOf("local-chatgpt:") !== 0) {
                  setQuickChatBinding(activeQuickChatThreadID, conversationID);
                } else {
                  var availableIDs = quickChatConversationIDs(panel);
                  var createdIDs = availableIDs.filter(function (conversationID) {
                    return activeQuickChatKnownConversationIDs.indexOf(conversationID) < 0;
                  });
                  if (createdIDs.length === 1) {
                    setQuickChatBinding(activeQuickChatThreadID, createdIDs[0]);
                    activeQuickChatKnownConversationIDs = availableIDs;
                  }
                }
              }
            } else if (quickChatWasOpen && !openingQuickChat) {
              quickChatWasOpen = false;
              activeQuickChatThreadID = null;
              activeQuickChatKnownConversationIDs = [];
            }
          }
          function newQuickChatButton(panel) {
            return Array.from(panel.querySelectorAll("button")).find(function (button) {
              var label = (button.getAttribute("aria-label") || "").toLowerCase();
              return label === "新對話" || label === "new chat";
            }) || null;
          }
          async function openQuickChatForThread(row) {
            if (openingQuickChat) return false;
            openingQuickChat = true;
            var succeeded = false;
            var threadID = row.getAttribute("data-app-action-sidebar-thread-id") || "";
            var previousActiveThreadID = activeQuickChatThreadID;
            activeQuickChatKnownConversationIDs = [];
            try {
              if (row.getAttribute("data-app-action-sidebar-thread-selected") !== "true") {
                row.click();
                await waitForQuickChat(function () {
                  return row.getAttribute("data-app-action-sidebar-thread-selected") === "true";
                }, 2000);
              }
              activeQuickChatThreadID = null;
              var panel = quickChatPanel();
              if (!panel) {
                var nativeButton = nativeQuickChatButton();
                if (!nativeButton) throw new Error("找不到內建 Quick Chat 入口");
                nativeButton.click();
                panel = await waitForQuickChat(quickChatPanel, 2500);
              }
              if (!panel) throw new Error("Quick Chat 未開啟");
              activeQuickChatKnownConversationIDs = quickChatConversationIDs(panel);
              activeQuickChatThreadID = threadID;

              var mappedID = normalizeQuickChatID(quickChatBindings[threadID]);
              var currentID = currentQuickChatID(panel);
              if (mappedID && quickChatLoadFailed(panel)) {
                var recoveryButton = newQuickChatButton(panel);
                if (recoveryButton) recoveryButton.click();
                await waitForQuickChat(function () {
                  var recoveredPanel = quickChatPanel();
                  return recoveredPanel && !quickChatLoadFailed(recoveredPanel) ? recoveredPanel : null;
                }, 2500);
                panel = quickChatPanel() || panel;
                currentID = currentQuickChatID(panel);
                showToast("已離開錯誤畫面，正在重試原本的 Quick Chat 綁定。");
              }
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
                  throw new Error("原本的 Quick Chat 對話目前不在可用清單；綁定已保留，可稍後重試或按 × 解綁");
                } else {
                  var resumed = await waitForQuickChat(function () {
                    var nextPanel = quickChatPanel();
                    if (quickChatLoadFailed(nextPanel)) return "failed";
                    return currentQuickChatID(nextPanel) === mappedID ? "resumed" : null;
                  }, 4000);
                  if (resumed !== "resumed") {
                    panel = quickChatPanel() || panel;
                    var resetButton = newQuickChatButton(panel);
                    if (resetButton) resetButton.click();
                    throw new Error("原本的 Quick Chat 對話暫時無法載入；綁定已保留，可稍後重試或按 × 解綁");
                  }
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
              succeeded = true;
            } catch (error) {
              console.warn("c2c Quick Chat:", error);
              showToast(error && error.message ? error.message : "Quick Chat 開啟失敗");
            } finally {
              openingQuickChat = false;
              captureActiveQuickChat();
              scheduleQuickChatScan();
            }
            return succeeded;
          }
          function quickChatIcon() {
            return '<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16"><path d="M7.983 5.304a.526.526 0 01.526.526v1.649h1.649a.525.525 0 110 1.051H8.509v1.65a.526.526 0 01-1.051 0V8.53h-1.65a.525.525 0 110-1.051h1.65V5.83a.526.526 0 01.525-.526z" fill="currentColor"/><path fill-rule="evenodd" d="M8 1.808c3.575 0 6.525 2.745 6.525 6.192 0 3.448-2.95 6.192-6.525 6.192-1.215 0-2.241-.363-3.245-.832l-1.768.459a.66.66 0 01-.807-.78l.37-1.675C2.036 10.36 1.475 9.382 1.475 8 1.475 4.553 4.425 1.808 8 1.808zm0 1.051C4.948 2.859 2.525 5.189 2.525 8c0 1.134.455 1.883 1.027 3.015a.65.65 0 01.054.44l-.263 1.186 1.283-.332a.65.65 0 01.45.043l.366.17c.85.378 1.65.62 2.558.62 3.052 0 5.474-2.33 5.475-5.142 0-2.811-2.423-5.141-5.475-5.141z" fill="currentColor"/></svg>';
          }
          function unbindQuickChatIcon() {
            return '<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16"><path d="M4.25 4.25l7.5 7.5m0-7.5l-7.5 7.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
          }
          function workspaceForSession(row) {
            var fiber = reactFiber(row);
            for (var depth = 0; fiber && depth < 30; depth++, fiber = fiber.return) {
              var props = fiber.memoizedProps;
              if (!props || typeof props.displayCwd !== "string" || props.displayCwd.indexOf("/") !== 0) continue;
              var path = props.displayCwd.replace(/\\/+$/, "") || "/";
              var label = typeof props.hoverCardProjectLabel === "string" && props.hoverCardProjectLabel
                ? props.hoverCardProjectLabel
                : (path.split("/").filter(Boolean).pop() || DEFAULT_WORKSPACE);
              return { path: path, label: label };
            }
            return null;
          }
          function attachmentActionLabel() {
            return attachmentState.hasPendingBatch && attachmentState.threadID === sessionMenuThreadID
              ? "送出後附加下一批（剩 " + (attachmentState.remainingCount || 0) + " 個）"
              : "附加「" + (sessionMenuWorkspace ? sessionMenuWorkspace.label : "此 session") + "」專案檔案";
          }
          function closeSessionMenu() {
            if (sessionMenu) sessionMenu.remove();
            sessionMenu = null;
            sessionMenuThreadID = null;
            sessionMenuWorkspace = null;
          }
          function syncSessionMenu() {
            if (!sessionMenu) return;
            var workspace = sessionMenu.querySelector("[data-c2c-session-menu-workspace]");
            if (workspace) workspace.textContent = sessionMenuWorkspace
              ? "工作目錄：" + sessionMenuWorkspace.path
              : "找不到這個 session 的工作目錄";
            var attach = sessionMenu.querySelector('[data-c2c-session-action="attach"]');
            if (attach) attach.textContent = attachmentActionLabel();
            var ignore = sessionMenu.querySelector('[data-c2c-session-action="ignore"]');
            if (ignore) ignore.textContent = "編輯「" + (sessionMenuWorkspace ? sessionMenuWorkspace.label : "此 session") + "」排除規則…";
            var statusNode = sessionMenu.querySelector("[data-c2c-session-menu-status]");
            if (statusNode) statusNode.textContent = sessionMenuStatus;
            sessionMenu.querySelectorAll("button").forEach(function (button) {
              var needsWorkspace = button.getAttribute("data-c2c-session-action") !== "open";
              button.disabled = sessionMenuBusy || (needsWorkspace && !sessionMenuWorkspace);
            });
          }
          function positionSessionMenu(anchor) {
            if (!sessionMenu || !anchor) return;
            var rect = anchor.getBoundingClientRect();
            var width = sessionMenu.offsetWidth || 236;
            var height = sessionMenu.offsetHeight || 150;
            var left = Math.min(rect.right + 8, window.innerWidth - width - 8);
            var top = Math.min(Math.max(rect.top - 8, 8), window.innerHeight - height - 8);
            sessionMenu.style.left = Math.max(left, 8) + "px";
            sessionMenu.style.top = Math.max(top, 8) + "px";
          }
          function openSessionMenu(row, anchor) {
            var threadID = row.getAttribute("data-app-action-sidebar-thread-id") || "";
            if (sessionMenu && sessionMenuThreadID === threadID) { closeSessionMenu(); return; }
            closeSessionMenu();
            sessionMenuThreadID = threadID;
            sessionMenuWorkspace = workspaceForSession(row);
            sessionMenuStatus = "";
            var menu = document.createElement("div");
            menu.setAttribute("data-c2c-session-menu", "true");
            var title = document.createElement("div");
            title.setAttribute("data-c2c-session-menu-title", "true");
            title.textContent = row.getAttribute("data-app-action-sidebar-thread-title") || "這個 session";
            var workspace = document.createElement("div");
            workspace.setAttribute("data-c2c-session-menu-workspace", "true");
            var openButton = document.createElement("button");
            openButton.type = "button";
            openButton.setAttribute("data-c2c-session-action", "open");
            openButton.textContent = quickChatBindings[threadID] ? "繼續 Quick Chat" : "開啟新的 Quick Chat";
            openButton.addEventListener("click", async function () {
              closeSessionMenu();
              await openQuickChatForThread(row);
            });
            var attach = document.createElement("button");
            attach.type = "button";
            attach.setAttribute("data-c2c-session-action", "attach");
            attach.addEventListener("click", async function () {
              var selectedWorkspace = sessionMenuWorkspace;
              closeSessionMenu();
              if (selectedWorkspace && await openQuickChatForThread(row)) {
                callNative("attach-workspace-files", false, threadID, selectedWorkspace.path);
              }
            });
            var ignore = document.createElement("button");
            ignore.type = "button";
            ignore.setAttribute("data-c2c-session-action", "ignore");
            ignore.addEventListener("click", function () {
              var selectedWorkspace = sessionMenuWorkspace;
              closeSessionMenu();
              if (selectedWorkspace) callNative("edit-ignore-rules", false, threadID, selectedWorkspace.path);
            });
            var statusNode = document.createElement("div");
            statusNode.setAttribute("data-c2c-session-menu-status", "true");
            menu.appendChild(title);
            menu.appendChild(workspace);
            menu.appendChild(openButton);
            menu.appendChild(attach);
            menu.appendChild(ignore);
            menu.appendChild(statusNode);
            document.body.appendChild(menu);
            sessionMenu = menu;
            syncSessionMenu();
            positionSessionMenu(anchor);
            if (sessionMenuWorkspace) callNative("get-state", true, threadID, sessionMenuWorkspace.path);
          }
          function dismissSessionMenu(event) {
            if (!sessionMenu) return;
            if (event.type === "keydown" && event.key !== "Escape") return;
            if (event.type === "pointerdown" && (sessionMenu.contains(event.target) || event.target.closest('[data-c2c-quick-chat-button="true"]'))) return;
            closeSessionMenu();
          }
          document.addEventListener("pointerdown", dismissSessionMenu, true);
          document.addEventListener("keydown", dismissSessionMenu, true);
          window.addEventListener("resize", closeSessionMenu);
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
                openSessionMenu(row, button);
              });
              row.appendChild(button);
            }
            var title = row.getAttribute("data-app-action-sidebar-thread-title") || "這個 session";
            var hasChat = !!quickChatBindings[threadID];
            row.setAttribute("data-c2c-quick-chat-state", hasChat ? "bound" : "unbound");
            button.setAttribute("data-c2c-has-chat", hasChat ? "true" : "false");
            button.setAttribute("aria-label", "開啟「" + title + "」的 ChatGPT 專案選單");
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
          quickChatCaptureTimer = window.setInterval(captureActiveQuickChat, 500);
          window[QUICK_CHAT_CLEANUP] = function () {
            quickChatDisposed = true;
            quickChatObserver.disconnect();
            closeSessionMenu();
            document.removeEventListener("pointerdown", dismissSessionMenu, true);
            document.removeEventListener("keydown", dismissSessionMenu, true);
            window.removeEventListener("resize", closeSessionMenu);
            if (quickChatCaptureTimer) window.clearInterval(quickChatCaptureTimer);
            quickChatCaptureTimer = 0;
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
          function setStatus(message) {
            sessionMenuStatus = message;
            syncSessionMenu();
          }
          function setBusy(busy) {
            sessionMenuBusy = busy;
            syncSessionMenu();
          }
          function updateQueueState(payload) {
            attachmentState.hasPendingBatch = payload.hasPendingBatch === true;
            attachmentState.remainingCount = payload.remainingCount || 0;
            attachmentState.threadID = payload.attachmentThreadID || "";
            syncSessionMenu();
          }
          function callNative(action, silent, threadID, workspacePath) {
            if (typeof window[BINDING] !== "function") {
              showToast("工作目錄連線尚未就緒，請確認 c2c 仍在執行。");
              return;
            }
            setBusy(true);
            if (!silent) setStatus("處理中…");
            try { window[BINDING](JSON.stringify({
              action: action,
              threadID: threadID || "",
              workspacePath: workspacePath || ""
            })); }
            catch (error) { setBusy(false); setStatus(""); showToast("無法呼叫 c2c：" + error); }
          }
          window[RESULT] = function (payloadText) {
            var payload = null;
            try { payload = JSON.parse(String(payloadText)); } catch (error) {}
            setBusy(false);
            if (!payload || typeof payload !== "object") { setStatus(""); showToast("c2c 回應無法解析。"); return; }
            if (payload.ok === true) {
              if (payload.action === "state") {
                updateQueueState(payload);
              } else if (payload.action === "edit-ignore-rules") {
                attachmentState.hasPendingBatch = false;
                attachmentState.remainingCount = 0;
                attachmentState.threadID = "";
                setStatus("已開啟 .c2cignore");
                showToast("排除規則已用文字編輯器開啟；儲存後，下次附加會自動重新載入。");
              } else if (payload.action === "attach-workspace-files") {
                var count = payload.count || 0;
                var batchNumber = payload.batchNumber || 1;
                var batchCount = payload.batchCount || 1;
                var remainingCount = payload.remainingCount || 0;
                setStatus("已附加第 " + batchNumber + "/" + batchCount + " 批（" + count + " 個）");
                if (payload.hasMore === true) {
                  attachmentState.hasPendingBatch = true;
                  attachmentState.remainingCount = remainingCount;
                  attachmentState.threadID = payload.threadID || "";
                  showToast("第 " + batchNumber + "/" + batchCount + " 批已附加。請先送出這則訊息，再按下一批。" +
                    (payload.incomplete === true ? " 部分檔案因無法安全讀取而未列入。" : ""));
                } else {
                  attachmentState.hasPendingBatch = false;
                  attachmentState.remainingCount = 0;
                  attachmentState.threadID = "";
                  showToast(payload.incomplete === true
                    ? "可安全讀取的批次已完成；部分檔案未列入。"
                    : "第 " + batchNumber + "/" + batchCount + " 批已附加；全部批次完成。");
                }
                syncSessionMenu();
              }
            } else if (payload.cancelled === true) {
              setStatus(""); showToast("已取消。");
            } else {
              setStatus(""); showToast(payload.error || "讀取工作目錄失敗。");
            }
          };
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
