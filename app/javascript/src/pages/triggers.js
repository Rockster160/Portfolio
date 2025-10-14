document.addEventListener("click", (e) => {
  const btn = e.target.closest(".execute-btn");
  if (!btn) return;

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
            }, 1000);
          },
          received: function (json) {
            synced = true;
            clearInterval(syncInterval);
            if (json?.data?.text) {
              executeBtn.querySelector(".execute-btn-title").textContent =
                json.data.text;
            }
            if (json?.data?.color) {
              executeWrapper.style.setProperty("--btn-color", json.data.color);
            }
          },
        });
      }
    });
});
