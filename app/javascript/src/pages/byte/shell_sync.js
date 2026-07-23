// Coordination layer between the page and the byte service worker.
// Handles SW registration, listens for shell_synced / shell_sync_failed
// messages, and exposes verify_ready / refresh_shells requests via
// postMessage + MessageChannel.

const WORKER_URL = "/byte_worker.js";

export async function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return null;
  try {
    const existing = await navigator.serviceWorker.getRegistration("/");
    if (existing) return existing;
    return await navigator.serviceWorker.register(WORKER_URL, { scope: "/" });
  } catch (e) {
    console.warn("[byte] SW register failed", e);
    return null;
  }
}

// Subscribe to SW broadcasts. `shell_updated` means the newly-fetched
// shell actually differs from the previously-cached one — an "update is
// available" signal for the reload button.
export function onShellSync(listener) {
  if (!("serviceWorker" in navigator)) return () => {};
  const handler = (evt) => {
    const kind = evt.data?.kind;
    if (
      kind === "shell_synced" ||
      kind === "shell_sync_failed" ||
      kind === "shell_updated" ||
      kind === "sw_version"
    ) {
      listener(evt.data);
    }
  };
  navigator.serviceWorker.addEventListener("message", handler);
  return () => navigator.serviceWorker.removeEventListener("message", handler);
}

// Ask the browser to check for a new SW file NOW (rather than waiting
// for its own periodic check, which can be up to 24h). Called on the
// visibilitychange → visible path so returning to the app pings the
// server for a new worker as well as a new shell.
export async function checkForServiceWorkerUpdate() {
  const reg = await navigator.serviceWorker?.getRegistration("/");
  if (!reg) return;
  try { await reg.update(); } catch (_) {}
}

// Whether an installed-but-not-yet-active SW is waiting to take over —
// the reload icon uses this to know a fresh worker is ready.
export async function hasWaitingServiceWorker() {
  const reg = await navigator.serviceWorker?.getRegistration("/");
  return !!reg?.waiting;
}

export async function requestShellRefresh() {
  const reg = await navigator.serviceWorker?.getRegistration("/");
  reg?.active?.postMessage({ action: "refresh_shells" });
}

// Round-trip verify — asks the SW whether every shell + asset is cached.
// Uses a MessageChannel so we can await a response; times out after 3s
// so a hung SW doesn't leave callers hanging forever.
export async function verifyShellReady() {
  const reg = await navigator.serviceWorker?.getRegistration("/");
  if (!reg?.active) return { ok: false, reason: "no active sw" };

  return new Promise((resolve) => {
    const channel = new MessageChannel();
    const timeout = setTimeout(() => resolve({ ok: false, reason: "timeout" }), 3000);
    channel.port1.onmessage = (evt) => {
      clearTimeout(timeout);
      resolve(evt.data);
    };
    try {
      reg.active.postMessage({ action: "verify_ready" }, [channel.port2]);
    } catch (e) {
      clearTimeout(timeout);
      resolve({ ok: false, reason: `postMessage: ${e.message}` });
    }
  });
}
