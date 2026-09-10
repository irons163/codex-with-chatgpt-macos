import Foundation

public enum EntryPanel {
    public static let marker = "__c2cEntryInstalled"
    public static let bindingName = "c2cEntryUpload"
    public static let resultFunction = "__c2cEntryResult"
    public static let hostID = "c2c-entry-host"

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
          var BINDING = "\(bindingName)";
          var RESULT = "\(resultFunction)";
          if (window[MARKER]) return "already";
          window[MARKER] = true;
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
            ".toast{position:absolute;right:0;bottom:92px;max-width:280px;padding:8px 10px;border-radius:8px;background:rgba(18,18,20,0.96);border:1px solid rgba(255,255,255,0.14);color:#ddd;font-size:11px;display:none}",
            ".toast.show{display:block}"
          ].join("");
          shadow.appendChild(style);
          var bubble = document.createElement("div");
          bubble.className = "bubble";
          bubble.title = "c2c 上傳入口";
          bubble.innerHTML = '<svg viewBox="0 0 24 24"><path d="M12 2l6 6h-4v7h-4V8H6l6-6zm-7 18h14v2H5v-2z"/></svg>';
          var panel = document.createElement("div");
          panel.className = "panel";
          var heading = document.createElement("h1");
          heading.textContent = "上傳入口";
          var hint = document.createElement("p");
          hint.textContent = "工作區：" + WORKSPACE;
          var attachButton = document.createElement("button");
          attachButton.textContent = "附加檔案到目前對話";
          var uploadButton = document.createElement("button");
          uploadButton.textContent = "上傳檔案到工作區";
          var status = document.createElement("div");
          status.className = "status";
          var toast = document.createElement("div");
          toast.className = "toast";
          panel.appendChild(heading);
          panel.appendChild(hint);
          panel.appendChild(attachButton);
          panel.appendChild(uploadButton);
          panel.appendChild(status);
          shadow.appendChild(bubble);
          shadow.appendChild(panel);
          shadow.appendChild(toast);
          document.documentElement.appendChild(host);
          var toastTimer = 0;
          function showToast(message) {
            toast.textContent = message;
            toast.classList.add("show");
            clearTimeout(toastTimer);
            toastTimer = setTimeout(function () { toast.classList.remove("show"); }, 4000);
          }
          function setStatus(message) { status.textContent = message; }
          function findAttachButton() {
            var nodes = document.querySelectorAll('button,[role="button"]');
            for (var i = 0; i < nodes.length; i++) {
              var label = nodes[i].getAttribute("aria-label") || "";
              if (/新增檔案|添加文件|ファイルを追加|파일 추가|attach|add files?/i.test(label)
                  && !/選單|menu|profile|个人资料|個人檔案/i.test(label)) return nodes[i];
            }
            return null;
          }
          function clickInput(input) {
            try { input.click(); showToast("已開啟檔案選擇視窗。"); }
            catch (error) { showToast("無法開啟檔案選擇視窗：" + error); }
          }
          function attachToConversation() {
            var existing = document.querySelector('input[type="file"]');
            if (existing) { clickInput(existing); return; }
            var button = findAttachButton();
            if (!button) { showToast("找不到附加檔案按鈕，請使用應用程式內建功能。"); return; }
            button.click();
            var tries = 0;
            var timer = setInterval(function () {
              tries += 1;
              var input = document.querySelector('input[type="file"]');
              if (input) { clearInterval(timer); clickInput(input); return; }
              if (tries >= 10) { clearInterval(timer); showToast("已開啟附加選單，請從中選擇檔案來源。"); }
            }, 150);
          }
          function uploadToWorkspace() {
            if (typeof window[BINDING] !== "function") {
              showToast("c2c 連線尚未就緒，請確認 c2c entry 仍在執行。");
              return;
            }
            setStatus("處理中…");
            try { window[BINDING](JSON.stringify({ action: "upload" })); }
            catch (error) { setStatus(""); showToast("無法呼叫 c2c：" + error); }
          }
          attachButton.addEventListener("click", attachToConversation);
          uploadButton.addEventListener("click", uploadToWorkspace);
          window[RESULT] = function (payloadText) {
            var payload = null;
            try { payload = JSON.parse(String(payloadText)); } catch (error) {}
            if (!payload || typeof payload !== "object") { setStatus(""); showToast("c2c 回應無法解析。"); return; }
            if (payload.ok === true) {
              var names = Array.isArray(payload.files) ? payload.files.join("、") : "";
              setStatus("已上傳 " + (payload.count || 0) + " 個檔案");
              showToast("已上傳 " + (payload.count || 0) + " 個檔案" + (names ? "：" + names : ""));
            } else if (payload.cancelled === true) {
              setStatus(""); showToast("已取消。");
            } else {
              setStatus(""); showToast(payload.error || "上傳失敗。");
            }
          };
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
          var host = document.getElementById("\(hostID)");
          if (host && host.parentNode) host.parentNode.removeChild(host);
          try { delete window.\(marker); } catch (error) { window.\(marker) = undefined; }
          try { delete window.\(resultFunction); } catch (error) { window.\(resultFunction) = undefined; }
        })();
        """
}
