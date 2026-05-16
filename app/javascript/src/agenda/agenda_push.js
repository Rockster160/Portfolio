// Registers /agenda_worker.js and subscribes against
// /push_notification_subscribe (channel: "agenda"). Auto-recovers from iOS
// subscription drops, respects the explicit opt-out flag.

const VAPID_PUBLIC_KEY =
  "BO7gUf6gNtfyxWRaYVjmL38uqi8TGKZZ9Fw7tEKzxCosTAtTERuv2ohHEiNB21CBs7ue5eOWMe2p4jtZjZTTAFU=";

const WORKER_URL = "/agenda_worker.js";
const WORKER_SCOPE = "/agenda";
const OPT_OUT_KEY = "agenda-push-opted-out";

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

async function getAgendaRegistration() {
  if (!("serviceWorker" in navigator)) return null;
  return navigator.serviceWorker.getRegistration(WORKER_SCOPE);
}

async function logPushDiagnostic(event, data = {}) {
  try {
    await fetch("/push_diagnostic", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        event: `agenda:${event}`,
        permission:
          typeof Notification !== "undefined"
            ? Notification.permission
            : "unsupported",
        optedOut: localStorage.getItem(OPT_OUT_KEY),
        timestamp: new Date().toISOString(),
        ...data,
      }),
      credentials: "same-origin",
    });
  } catch (_e) {
    /* ignore — diagnostics shouldn't block UX */
  }
}

// Idempotent: registers the SW, re-subscribes if iOS dropped the
// subscription, syncs to the server. Safe to call on every page load.
export async function ensureAgendaServiceWorker() {
  if (!("serviceWorker" in navigator)) return "unsupported";

  // The SW must register even on browsers without PushManager — it's what
  // makes the page installable as a PWA.
  let registration;
  try {
    registration = await navigator.serviceWorker.getRegistration(WORKER_SCOPE);
    if (!registration) {
      registration = await navigator.serviceWorker.register(WORKER_URL, {
        scope: WORKER_SCOPE,
      });
    }
  } catch (e) {
    logPushDiagnostic("sw_register_error", { error: e.message });
    return "unsupported";
  }

  if (!("PushManager" in window) || typeof Notification === "undefined") {
    return "registered_no_push";
  }
  if (Notification.permission === "denied") return "denied";

  try {
    let subscription = await registration.pushManager.getSubscription();
    const userOptedOut = localStorage.getItem(OPT_OUT_KEY) === "true";

    // iOS Safari drops the push subscription when the app is killed —
    // silently re-subscribe if permission is still granted.
    if (
      !subscription &&
      Notification.permission === "granted" &&
      !userOptedOut
    ) {
      try {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
        });
        logPushDiagnostic("auto_recovery_success");
      } catch (subError) {
        logPushDiagnostic("auto_recovery_failed", { error: subError.message });
      }
    }

    if (!subscription) return "unsubscribed";

    localStorage.removeItem(OPT_OUT_KEY);
    const subscriptionData = subscription.toJSON();
    subscriptionData.channel = "agenda";

    await fetch("/push_notification_subscribe", {
      method: "POST",
      headers: { "Content-Type": "application/json", JarvisPushVersion: "2" },
      body: JSON.stringify(subscriptionData),
      credentials: "same-origin",
    });

    return "subscribed";
  } catch (e) {
    logPushDiagnostic("ensure_error", { error: e.message });
    return "unsubscribed";
  }
}

export async function checkAgendaNotificationStatus() {
  if (!("serviceWorker" in navigator) || !("Notification" in window)) {
    return "unsupported";
  }
  if (Notification.permission === "denied") return "denied";

  try {
    const reg = await getAgendaRegistration();
    if (!reg) return "unsubscribed";
    const sub = await reg.pushManager.getSubscription();
    return sub ? "subscribed" : "unsubscribed";
  } catch (_e) {
    return "unsubscribed";
  }
}

// Explicit opt-in — must be called from a user gesture so the browser
// shows the permission prompt.
export async function registerAgendaNotifications() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return { success: false, error: "unsupported" };
  }

  try {
    localStorage.removeItem(OPT_OUT_KEY);

    const registration = await navigator.serviceWorker.register(WORKER_URL, {
      scope: WORKER_SCOPE,
    });
    if (registration.installing || registration.waiting) {
      await new Promise((resolve) => {
        const worker = registration.installing || registration.waiting;
        worker.addEventListener("statechange", () => {
          if (worker.state === "activated") resolve();
        });
        if (registration.active) resolve();
      });
    }

    const permission = await Notification.requestPermission();
    if (permission !== "granted")
      return { success: false, error: "permission_denied" };

    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    });

    const subscriptionData = subscription.toJSON();
    subscriptionData.channel = "agenda";

    const response = await fetch("/push_notification_subscribe", {
      method: "POST",
      headers: { "Content-Type": "application/json", JarvisPushVersion: "2" },
      body: JSON.stringify(subscriptionData),
      credentials: "same-origin",
    });

    if (response.ok) return { success: true };
    // Roll the browser subscription back when the server rejects it.
    await subscription.unsubscribe();
    return { success: false, error: "server_error" };
  } catch (error) {
    const sub = await (
      await getAgendaRegistration()
    )?.pushManager.getSubscription();
    if (sub) await sub.unsubscribe();
    return { success: false, error: error.message };
  }
}

export async function unregisterAgendaNotifications() {
  try {
    localStorage.setItem(OPT_OUT_KEY, "true");
    const reg = await getAgendaRegistration();
    const subscription = await reg?.pushManager.getSubscription();
    if (subscription) {
      const subscriptionData = subscription.toJSON();
      subscriptionData.channel = "agenda";
      await fetch("/push_notification_unsubscribe", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(subscriptionData),
        credentials: "same-origin",
      }).catch(() => {});
      await subscription.unsubscribe();
    }
    return { success: true };
  } catch (error) {
    return { success: false, error: error.message };
  }
}

// Exposed on window so settings UI + the agenda.js IIFE can call into
// these without an ES-module import.
if (typeof window !== "undefined") {
  window.AgendaPush = {
    ensure: ensureAgendaServiceWorker,
    check: checkAgendaNotificationStatus,
    register: registerAgendaNotifications,
    unregister: unregisterAgendaNotifications,
  };
}

// Auto-register on every Agenda surface so the PWA install affordance
// stays present and iOS-dropped subscriptions self-heal on focus.
function isOnAgendaSurface() {
  return !!document.querySelector(
    ".agenda-page, .agenda-calendar-page, .agenda-settings-page, .agendas-index-container",
  );
}

document.addEventListener("DOMContentLoaded", () => {
  if (!isOnAgendaSurface()) return;
  ensureAgendaServiceWorker();
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (!isOnAgendaSurface()) return;
  ensureAgendaServiceWorker();
});
