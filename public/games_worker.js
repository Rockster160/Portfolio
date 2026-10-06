// Game Tracker service worker. Offline-first shell cache for /games only -
// mutations never go through the SW; the page's localStorage queue
// (offline_queue.js) owns retries. Adapted from timers_worker.js.

const CACHE = "games-v6";

// Only the two STATIC shells - /games/plays/:id is dynamic (live while
// active, read-only once finished) and must never be served stale from a
// cache; it just falls through to the network like any other page.
function isShellRequest(url) {
  if (url.origin !== location.origin) return false;
  if (url.search) return false;
  return url.pathname === "/games" || url.pathname === "/games/new";
}

function isPrecachableAsset(url) {
  if (url.origin !== location.origin) return false;
  if (url.search) return false;
  if (url.pathname.startsWith("/assets/")) return true;
  if (url.pathname.endsWith(".webmanifest")) return true;
  return false;
}

self.addEventListener("install", (evt) => {
  evt.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(["/games", "/games/new"]).catch(() => null)),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (evt) => {
  evt.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys.filter((k) => k.startsWith("games-") && k !== CACHE).map((k) => caches.delete(k)),
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
  }
});

async function networkFirstShell(req, url) {
  const cache = await caches.open(CACHE);
  try {
    const fresh = await fetch(req, { cache: "no-store" });
    if (fresh && fresh.ok) {
      cache.put(url.pathname, fresh.clone());
      return fresh;
    }
  } catch (e) { /* offline - fall through to cache */ }
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
