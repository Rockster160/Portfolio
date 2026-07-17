document.addEventListener("click", (e) => {
  const btn = e.target.closest(".execute-btn");
  if (!btn) return;
  // Function tasks open a modal — let jil_run_modal own the disable/enable.
  if (btn.closest(".execute-btn-wrapper[data-function-args]")) return;

  btn.style.pointerEvents = "none";
  btn.classList.add("disabled");
});

const reenable = (el) => {
  if (!el) return;
  el.style.pointerEvents = "";
  el.classList.remove("disabled");
};

const flash = (wrapper) => {
  if (!wrapper) return;
  wrapper.querySelectorAll(".execute-success-msg").forEach((n) => n.remove());
  const messageWrapper = wrapper.querySelector(".message-wrapper");

  const msg = document.createElement("span");
  msg.textContent = "Triggered!";
  msg.className = "execute-success-msg";
  messageWrapper.appendChild(msg);

  const prev = wrapper.dataset.msgTimeoutId;
  if (prev) clearTimeout(Number(prev));

  const id = setTimeout(() => msg.remove(), 1500);
  wrapper.dataset.msgTimeoutId = String(id);
};

document.addEventListener("ajax:success", (e) => {
  const btn = e.target.closest(".execute-btn");
  const wrapper = btn ? btn.closest(".execute-btn-wrapper") : null;
  reenable(btn);
  flash(wrapper);
});

document.addEventListener("ajax:error", (e) => {
  const btn = e.target.closest(".execute-btn");
  console.log("Error executing trigger:", e);
  reenable(btn);
});

import { HouseholdIconPool } from "../household_icon_pool";

const splitGraphemes = (s) => {
  if (window.Intl && Intl.Segmenter) {
    const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    return Array.from(seg.segment(s), (x) => x.segment);
  }
  return Array.from(s);
};

const HICON_RX = /\[hicon (.*?)\]/gi;

const setButtonText = (titleEl, text) => {
  const stackMatch = text.match(/^\[stack (.+)\]$/);
  if (stackMatch) {
    const graphemes = splitGraphemes(stackMatch[1].trim());
    titleEl.textContent = "";
    const stack = document.createElement("i");
    stack.className = "stacked-emoji";
    graphemes.forEach((g) => {
      const span = document.createElement("span");
      span.textContent = g;
      stack.appendChild(span);
    });
    titleEl.appendChild(stack);
  } else if (HICON_RX.test(text)) {
    // innerHTML is only safe once we've escaped the non-hicon parts —
    // broadcast text can be arbitrary and could otherwise inject markup.
    HICON_RX.lastIndex = 0;
    const escape = (s) =>
      s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    let out = "";
    let cursor = 0;
    text.replace(HICON_RX, (match, name, offset) => {
      out += escape(text.slice(cursor, offset));
      out += HouseholdIconPool.markupHtml(name);
      cursor = offset + match.length;
      return match;
    });
    out += escape(text.slice(cursor));
    titleEl.innerHTML = out;
  } else {
    titleEl.textContent = text;
  }
};

document.addEventListener("DOMContentLoaded", function () {
  document
    .querySelectorAll(".execute-btn-wrapper")
    .forEach((executeWrapper) => {
      const executeBtn = executeWrapper.querySelector(".execute-btn");
      if (
        executeWrapper.dataset.type === "monitor" &&
        !executeWrapper.monitor
      ) {
        const monitorKey = executeWrapper.dataset.monitor;
        let synced = false;
        let syncInterval = undefined;
        executeWrapper.monitor = Monitor.subscribe(monitorKey, {
          connected: function () {
            executeWrapper.monitor?.resync();
            syncInterval = setInterval(() => {
              if (!synced) {
                console.log("resyncing monitor...");
                executeWrapper.monitor?.resync();
              }
            }, 3000);
          },
          received: function (json) {
            synced = true;
            clearInterval(syncInterval);
            if (json?.data?.text) {
              setButtonText(
                executeBtn.querySelector(".execute-btn-title"),
                json.data.text,
              );
            }
            if (json?.data?.color) {
              executeWrapper.style.setProperty("--btn-color", json.data.color);
            }
            if (json?.data?.fontSize) {
              executeWrapper.style.setProperty(
                "--btn-size",
                json.data.fontSize,
              );
            }
            const subtextEl = executeBtn.querySelector(".execute-btn-subtext");
            if (subtextEl) {
              subtextEl.textContent = json?.data?.subtext || "";
            }
          },
        });
      }
    });
});
