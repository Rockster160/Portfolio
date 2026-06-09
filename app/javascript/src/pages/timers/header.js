// Header buttons: sound (mute toggle), alerts (push subscribe / unsubscribe),
// settings (open modal). Alerts state is derived from BOTH the browser
// permission AND a live pushManager subscription — not just the permission —
// so the icon never lies. Toggle works as on/off, not just on/grant-prompt.

import { ensureTimersServiceWorker, requestTimersNotificationPermission, unsubscribeTimers } from "./push";
import { setMuted } from "./audio";

const MUTE_KEY = "timers:muted";

export function isMuted() {
  return localStorage.getItem(MUTE_KEY) === "true";
}

export function wireHeader({ root, openSettings }) {
  wireMute(root);
  wireAlerts(root);
  wireSettings(root, openSettings);
}

function wireMute(root) {
  const btn = root.querySelector("[data-timers-mute]");
  if (!btn) return;
  paintMute(btn);
  // Reflect initial mute state into the audio layer so deferred
  // pending sounds queued before this fires are cancelled too.
  setMuted(isMuted());
  btn.addEventListener("click", () => {
    const next = !isMuted();
    localStorage.setItem(MUTE_KEY, next ? "true" : "false");
    // setMuted(true) calls stopAllSounds() — every live cadence and
    // every deferred intent dies the instant the user mutes.
    setMuted(next);
    paintMute(btn);
  });
}

function paintMute(btn) {
  const muted = isMuted();
  btn.classList.toggle("is-muted", muted);
  btn.querySelector(".when-unmuted")?.classList.toggle("hidden", muted);
  btn.querySelector(".when-muted")?.classList.toggle("hidden", !muted);
  btn.setAttribute("aria-label", muted ? "Unmute" : "Mute");
  btn.setAttribute("title", muted ? "Sound muted" : "Sound on");
}

async function isReallySubscribed() {
  if (!("Notification" in window)) return false;
  if (Notification.permission !== "granted") return false;
  if (!("serviceWorker" in navigator)) return false;
  try {
    const reg = await navigator.serviceWorker.getRegistration("/timers");
    if (!reg) return false;
    const sub = await reg.pushManager.getSubscription();
    return !!sub;
  } catch (e) {
    return false;
  }
}

async function paintAlerts(btn) {
  const subscribed = await isReallySubscribed();
  btn.classList.toggle("is-active", subscribed);
  btn.querySelector(".when-subscribed")?.classList.toggle("hidden", !subscribed);
  btn.querySelector(".when-unsubscribed")?.classList.toggle("hidden", subscribed);
  btn.setAttribute("aria-label", subscribed ? "Disable alerts" : "Enable alerts");
  btn.setAttribute("title", subscribed ? "Alerts on — tap to disable" : "Alerts off — tap to enable");
}

function wireAlerts(root) {
  const btn = root.querySelector("[data-timers-notify]");
  if (!btn) return;
  if (!("Notification" in window)) { btn.remove(); return; }
  btn.classList.remove("hidden");

  ensureTimersServiceWorker().finally(() => paintAlerts(btn));

  btn.addEventListener("click", async () => {
    const wasOn = await isReallySubscribed();
    if (wasOn) {
      await unsubscribeTimers();
    } else {
      await requestTimersNotificationPermission();
    }
    await paintAlerts(btn);
  });
}

function wireSettings(root, openSettings) {
  const btn = root.querySelector("[data-timers-settings]");
  if (!btn) return;
  btn.addEventListener("click", () => openSettings?.());
}
