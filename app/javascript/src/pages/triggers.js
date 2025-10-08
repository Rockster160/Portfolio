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
  reenable(btn);
});
