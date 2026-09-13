import Foundation

public enum EntryPanel {
    public static let marker = "__c2cWorkspaceReaderInstalled"
    public static let version = "workspace-attachments-v3"
    public static let bindingName = "c2cWorkspaceReader"
    public static let resultFunction = "__c2cEntryResult"
    public static let hostID = "c2c-entry-host"

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
          var previousHost = document.getElementById("\(hostID)");
          if (window[MARKER] === VERSION && previousHost) return "already";
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
          var toastTimer = 0;
          function showToast(message) {
            toast.textContent = message;
            toast.classList.add("show");
            clearTimeout(toastTimer);
            toastTimer = setTimeout(function () { toast.classList.remove("show"); }, 4000);
          }
          function setStatus(message) { status.textContent = message; }
          function callNative(action) {
            if (typeof window[BINDING] !== "function") {
              showToast("工作目錄連線尚未就緒，請確認 c2c 仍在執行。");
              return;
            }
            setStatus("處理中…");
            try { window[BINDING](JSON.stringify({ action: action })); }
            catch (error) { setStatus(""); showToast("無法呼叫 c2c：" + error); }
          }
          chooseButton.addEventListener("click", function () { callNative("choose-workspace"); });
          attachButton.addEventListener("click", function () { callNative("attach-workspace-files"); });
          window[RESULT] = function (payloadText) {
            var payload = null;
            try { payload = JSON.parse(String(payloadText)); } catch (error) {}
            if (!payload || typeof payload !== "object") { setStatus(""); showToast("c2c 回應無法解析。"); return; }
            if (payload.ok === true) {
              if (payload.action === "choose-workspace") {
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
                  showToast("第 " + batchNumber + "/" + batchCount + " 批已附加。請先送出這則訊息，再按下一批。");
                } else {
                  attachButton.textContent = batchCount > 1 ? "從第一批重新開始" : "重新附加目前專案檔案";
                  showToast("第 " + batchNumber + "/" + batchCount + " 批已附加；全部批次完成。");
                }
              }
            } else if (payload.cancelled === true) {
              setStatus(""); showToast("已取消。");
            } else {
              setStatus(""); showToast(payload.error || "讀取工作目錄失敗。");
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
