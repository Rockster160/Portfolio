// Header buttons: sound (mute toggle), alerts (push subscribe / unsubscribe),
// settings (open modal). Alerts state is derived from BOTH the browser
// permission AND a live pushManager subscription — not just the permission —
// so the icon never lies. Toggle works as on/off, not just on/grant-prompt.

import { ensureTimersServiceWorker, requestTimersNotificationPermission, unsubscribeTimers } from "./push";
import { setMuted, subscribeAudioState, ensureRunningCtx, previewChime } from "./audio";

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
  // Reflect initial mute state into the audio layer so deferred
  // pending sounds queued before this fires are cancelled too.
  setMuted(isMuted());
  // Repaint whenever the engine transitions (suspended → running, etc).
  // Initial paint comes via the immediate cb in subscribeAudioState.
  subscribeAudioState((engineState) => paintMute(btn, engineState));

  btn.addEventListener("click", async () => {
    // Three-state cycle wired against engine + mute:
    //   inactive  → try to activate. Success → unmute + soft chime.
    //   running   → mute.
    //   muted     → unmute (activate first if engine is now stuck).
    const muted = isMuted();
    if (!muted) {
      const engine = (await ensureRunningCtx()) ? "running" : "inactive";
      if (engine === "inactive") {
        // Activation failed — leave unmuted so retry is one tap, but
        // surface the inactive icon so the user knows nothing will sound.
        paintMute(btn, "inactive");
        return;
      }
      // Activation worked AND we were unmuted → user wants OFF now.
      localStorage.setItem(MUTE_KEY, "true");
      setMuted(true);
      paintMute(btn, "running");
    } else {
      localStorage.setItem(MUTE_KEY, "false");
      const c = await ensureRunningCtx();
      setMuted(false);
      // Confirmation chime — proves to the user that audio is back.
      if (c) previewChime("ding");
      paintMute(btn, c ? "running" : "inactive");
    }
  });
}

function paintMute(btn, engineState) {
  const muted = isMuted();
  const inactive = !muted && engineState === "inactive";

  btn.classList.toggle("is-muted", muted);
  btn.classList.toggle("is-inactive", inactive);

  btn.querySelector(".when-unmuted")?.classList.toggle("hidden", muted || inactive);
  btn.querySelector(".when-muted")?.classList.toggle("hidden", !muted);
  btn.querySelector(".when-audio-inactive")?.classList.toggle("hidden", !inactive);

  const label = muted ? "Unmute" : inactive ? "Tap to enable sound" : "Mute";
  btn.setAttribute("aria-label", label);
  btn.setAttribute("title", label);
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
