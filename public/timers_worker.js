// Timers service worker.
//
// Combines two responsibilities:
//   1. Offline-first shell cache (stale-while-revalidate for /timers and
//      /timers/page/:slug). Cached on first fetch; refreshed in the
//      background. Lets the PWA boot from cache even with no reception.
//   2. Push notifications + click-through (mirrors agenda_worker.js).
//
// Mutations are NEVER served from the SW. The page-script's localStorage
// queue handles offline retries — POST/PATCH/DELETE fall through to the
// network, and a synthetic 503 is returned on failure so the queue can
// detect it.

const CACHE = "timers-v41";
const SHELL_PREFIX = "/timers";

function isShellRequest(url) {
  if (url.origin !== location.origin) return false;
  if (url.search) return false;
  return url.pathname === "/timers" || url.pathname.startsWith("/timers/page/");
}

function isPrecachableAsset(url) {
  if (url.origin !== location.origin) return false;
  if (url.pathname.startsWith("/assets/")) return true;
  if (url.pathname.startsWith("/assets/favicon/")) return true;
  if (url.pathname.endsWith(".webmanifest")) return true;
  return false;
}

self.addEventListener("install", (evt) => {
  evt.waitUntil(
    caches.open(CACHE).then((cache) =>
      cache.add("/timers").catch(() => null),
    ),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (evt) => {
  evt.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys.filter((k) => k.startsWith("timers-") && k !== CACHE).map((k) => caches.delete(k)),
    );
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (evt) => {
  const req = evt.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  if (url.origin !== location.origin) return;

  if (isShellRequest(url)) {
    evt.respondWith(networkFirstShell(req, url));
    return;
  }

  if (isPrecachableAsset(url)) {
    evt.respondWith(cacheFirst(req));
    return;
  }

  if (url.pathname.startsWith(SHELL_PREFIX) && req.headers.get("Accept")?.includes("application/json")) {
    evt.respondWith(networkFirstJson(req));
    return;
  }
});

// Network-first for shells: always try the live HTML so stale CSS/JS
// doesn't strand the user after a deploy. Falls back to cache only when
// the network actually fails (offline / 5xx).
async function networkFirstShell(req, url) {
  const cache = await caches.open(CACHE);
  try {
    const fresh = await fetch(req, { cache: "no-store" });
    if (fresh && fresh.ok) {
      cache.put(url.pathname, fresh.clone());
      return fresh;
    }
  } catch (e) { /* network failure — fall through */ }
  const cached = await cache.match(url.pathname);
  return cached || new Response("offline", { status: 503 });
}

async function cacheFirst(req) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(req);
  if (cached) return cached;

  const fresh = await fetch(req).catch(() => null);
  if (fresh && fresh.ok) cache.put(req, fresh.clone());
  return fresh || new Response("offline", { status: 503 });
}

async function networkFirstJson(req) {
  try {
    const res = await fetch(req);
    if (res && res.ok) {
      const cache = await caches.open(CACHE);
      cache.put(req, res.clone());
    }
    return res;
  } catch (e) {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req);
    return cached || new Response("offline", { status: 503 });
  }
}

// =========================
// Push notifications
// =========================

self.addEventListener("push", (evt) => {
  let data = {};
  try {
    data = evt.data ? evt.data.json() : {};
  } catch (e) {
    return;
  }

  if (data.dismiss && data.tag) {
    evt.waitUntil(
      self.registration.getNotifications({ tag: data.tag }).then((ns) => ns.forEach((n) => n.close())),
    );
    return;
  }

  data.icon = data.icon || "/assets/favicon/android-chrome-192x192.png";

  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title || "Timer", data));
  }
});

self.addEventListener("notificationclick", (evt) => {
  evt.notification.close();
  const targetUrl = evt.notification.data?.url || "/timers";

  evt.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        const url = new URL(client.url);
        if (url.pathname.startsWith("/timers") && "focus" in client) {
          if (client.url !== targetUrl && "navigate" in client) {
            return client.navigate(targetUrl).then(() => client.focus());
          }
          return client.focus();
        }
      }
      if (clients.openWindow) return clients.openWindow(targetUrl);
    }),
  );
});
