// Service worker + web-push registration for the Timers PWA. Mirrors
// agenda_push.js: idempotent registration, opt-out persistence, iOS
// auto-recovery path. The actual subscription body is POSTed to the
// existing /push_notification_subscribe endpoint with channel: "timers".

const VAPID_PUBLIC_KEY = "BO7gUf6gNtfyxWRaYVjmL38uqi8TGKZZ9Fw7tEKzxCosTAtTERuv2ohHEiNB21CBs7ue5eOWMe2p4jtZjZTTAFU=";
const WORKER_URL = "/timers_worker.js";
const WORKER_SCOPE = "/timers";
const OPT_OUT_KEY = "timers-push-opted-out";

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

async function csrfHeader() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
}

export async function ensureTimersServiceWorker() {
  if (!("serviceWorker" in navigator)) return null;
  try {
    const reg = await navigator.serviceWorker.register(WORKER_URL, { scope: WORKER_SCOPE });
    if (Notification.permission === "granted" && localStorage.getItem(OPT_OUT_KEY) !== "true") {
      await subscribeIfMissing(reg);
    }
    return reg;
  } catch (e) {
    console.warn("Timers SW registration failed:", e);
    return null;
  }
}

async function subscribeIfMissing(reg) {
  const existing = await reg.pushManager.getSubscription();
  if (existing) {
    await postSubscription(existing);
    return existing;
  }
  try {
    const sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    });
    await postSubscription(sub);
    return sub;
  } catch (e) {
    console.warn("Timers push subscribe failed:", e);
    return null;
  }
}

async function postSubscription(sub) {
  const json = sub.toJSON();
  await fetch("/push_notification_subscribe", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": await csrfHeader(),
    },
    body: JSON.stringify({
      endpoint: json.endpoint,
      p256dh:   json.keys?.p256dh,
      auth:     json.keys?.auth,
      channel:  "timers",
    }),
  }).catch(() => null);
}

export async function requestTimersNotificationPermission() {
  if (Notification.permission === "granted") {
    localStorage.removeItem(OPT_OUT_KEY);
    return ensureTimersServiceWorker();
  }
  const result = await Notification.requestPermission();
  if (result === "granted") {
    localStorage.removeItem(OPT_OUT_KEY);
    return ensureTimersServiceWorker();
  }
  localStorage.setItem(OPT_OUT_KEY, "true");
  return null;
}

export function notificationStatus() {
  if (!("Notification" in window)) return "unsupported";
  if (Notification.permission === "denied") return "denied";
  if (localStorage.getItem(OPT_OUT_KEY) === "true") return "opted-out";
  return Notification.permission === "granted" ? "subscribed" : "default";
}

export async function unsubscribeTimers() {
  localStorage.setItem(OPT_OUT_KEY, "true");
  if (!("serviceWorker" in navigator)) return;
  try {
    const reg = await navigator.serviceWorker.getRegistration(WORKER_SCOPE);
    const sub = await reg?.pushManager.getSubscription();
    if (sub) {
      await fetch("/push_notification_unsubscribe", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": await csrfHeader() },
        body: JSON.stringify({ endpoint: sub.endpoint, channel: "timers" }),
      }).catch(() => null);
      await sub.unsubscribe();
    }
  } catch (e) { /* ignore */ }
}
