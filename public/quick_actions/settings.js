import registerNotifications, { checkJarvisNotificationStatus } from "./push_subscribe.js";

const STATUS_LABEL = {
  registered: "Registered",
  unregistered: "Not registered",
  blocked: "Blocked by browser",
  unsupported: "Not supported",
};

const REGISTER_LABEL = {
  registered: "Re-register",
  unregistered: "Register",
  blocked: "Register",
  unsupported: "Register",
};

async function refreshNotificationStatus() {
  const wrapper = document.querySelector("#quick-actions-settings .notification-status");
  const button = document.querySelector("#register-notifications-btn");
  if (!wrapper || !button) return;

  const status = await checkJarvisNotificationStatus();
  wrapper.dataset.status = status;
  wrapper.querySelector(".status-text").textContent = STATUS_LABEL[status] || "Unknown";

  button.textContent = REGISTER_LABEL[status] || "Register";
  button.disabled = status === "unsupported" || status === "blocked";
}

document.addEventListener("modal:show", function (evt) {
  if (evt.target?.id === "quick-actions-settings") {
    refreshNotificationStatus();
  }
});

document.addEventListener("click", async function (evt) {
  if (!evt.target.closest("#register-notifications-btn")) return;
  evt.preventDefault();

  const button = evt.target.closest("#register-notifications-btn");
  const original = button.textContent;
  button.disabled = true;
  button.textContent = "Registering…";

  try {
    await registerNotifications();
  } finally {
    button.textContent = original;
    setTimeout(refreshNotificationStatus, 500);
  }
});
