// Chores service worker.
//
// Strategy:
//   * App shell (Today + Grid HTML) → stale-while-revalidate. Lets the
//     PWA boot from cache even with no reception. When network arrives
//     the cached shell is replaced silently for next load.
//   * Static assets (built JS/CSS, manifest, icons) → cache-first.
//   * API POSTs (complete a chore) → network-only. The page-script
//     handles the offline queue itself in localStorage so we don't have
//     to retry from inside the SW — but if a POST fails offline we
//     return a synthetic 503 so the page-script can queue it.
//   * Other GETs (balance, history) → network-first with cache fallback.
//
// Cache name is versioned: bump CACHE on shipping a new shell so old
// clients re-pull the HTML next time they're online.

// Bump CACHE on shipping shell changes so old clients re-pull HTML.
const CACHE = "chores-v56";
// Every chore view is a cached shell. Each shell is body-empty for
// page-specific content — entries on History, recent rows on Balance —
// because that data is hydrated client-side from JSON (and from a
// localStorage cache for instant repeat visits). The shell load itself
// is offline-tolerant; the JSON fetches degrade gracefully when there
// is no connection.
const SHELL_PATHS = ["/chores", "/chores/today", "/chores/balance", "/chores/history"];

// Match /assets/, /whisper_favicon/, .webmanifest, and the two
// non-pipelined chores_*.js files. Anything else (cross-origin, API
// endpoints, opaque resources) is intentionally skipped.
function isPrecachableAssetURL(url) {
  if (url.origin !== location.origin) return false;
  if (url.pathname.startsWith("/assets/")) return true;
  if (url.pathname.startsWith("/whisper_favicon/")) return true;
  if (url.pathname.endsWith(".webmanifest")) return true;
  if (url.pathname === "/chores_sortable.js") return true;
  return false;
}

// Parse a shell HTML body for asset URLs the page needs to render and
// warm them into the cache. Without this step, a content-hashed CSS/JS
// the cached HTML references can either 404 after a deploy (old hash
// purged from the public/ dir) or fail offline — either way the page
// boots into a black screen because the JS that hydrates it never
// loads. Warming the assets alongside the shell keeps the cache
// internally consistent.
async function warmShellAssets(cache, shellHtml, baseUrl) {
  const urls = new Set();
  const re = /\b(?:src|href)=["']([^"']+)["']/g;
  let m;
  while ((m = re.exec(shellHtml)) !== null) {
    let u;
    try { u = new URL(m[1], baseUrl); } catch (e) { continue; }
    if (isPrecachableAssetURL(u)) urls.add(u.toString());
  }
  await Promise.all(Array.from(urls).map(async u => {
    try {
      const existing = await cache.match(u);
      if (existing) return;
      const r = await fetch(u, { credentials: "same-origin", cache: "no-store" });
      if (r && r.ok) await cache.put(u, r.clone());
    } catch (e) { /* offline; nothing we can do */ }
  }));
}

// Background shell refresh — fired by the page-script when a Monitor
// broadcast lands or the tab regains focus. `cache: "no-store"` is
// critical: without it, fetch() inside a service worker still respects
// the browser's HTTP cache, which can serve stale HTML and re-poison
// our SW cache with it.
async function refreshAllShells() {
  const cache = await caches.open(CACHE);
  // Per-path success/failure tracked so the page's syncing badge can
  // turn off as soon as ANY path lands. The fetch-intercept path
  // already broadcasts `shell_synced` per path; the explicit-message
  // path used to swallow the signal, which left the badge stuck
  // forever after a local save.
  await Promise.all(SHELL_PATHS.map(async p => {
    try {
      const r = await fetch(p, { credentials: "same-origin", redirect: "manual", cache: "no-store" });
      if (r && r.ok && r.type !== "opaqueredirect") {
        const clone = r.clone();
        await cache.put(p, r.clone());
        const html = await clone.text();
        await warmShellAssets(cache, html, new URL(p, location.origin).toString());
        await broadcastToClients({ kind: "shell_synced", path: p });
      } else {
        await broadcastToClients({ kind: "shell_sync_failed", path: p });
      }
    } catch (e) {
      await broadcastToClients({ kind: "shell_sync_failed", path: p });
    }
  }));
}

self.addEventListener("message", evt => {
  if (evt.data?.action === "refresh_shells") {
    evt.waitUntil(refreshAllShells());
  }
});

async function broadcastToClients(payload) {
  const clients = await self.clients.matchAll({ includeUncontrolled: true });
  clients.forEach(c => c.postMessage(payload));
}

self.addEventListener("install", evt => {
  evt.waitUntil(refreshAllShells());
  self.skipWaiting();
});

self.addEventListener("activate", evt => {
  evt.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k.startsWith("chores-") && k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

function isShellRequest(url) {
  // History is excluded above from SHELL_PATHS entirely. The remaining
  // shells (Grid / Today / Balance) are not paginated, so an exact
  // pathname match is enough — any query string falls through to the
  // network.
  if (url.search) return false;
  return SHELL_PATHS.includes(url.pathname);
}

function isStaticAsset(url) {
  return url.pathname.startsWith("/assets/") ||
    url.pathname.startsWith("/whisper_favicon/") ||
    url.pathname.endsWith(".webmanifest");
}

self.addEventListener("fetch", evt => {
  const req = evt.request;
  if (req.method !== "GET") {
    // Mutations are never served from the SW. Let the page-script's
    // localStorage queue handle offline retries.
    return;
  }
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;

  if (isShellRequest(url)) {
    // Cache-first with background revalidate (stale-while-revalidate).
    // Critical for PWA feel: every page boot is INSTANT from cache and
    // loads with no network round-trip, then a "syncing" badge stays
    // visible until the background fetch finishes and the SW posts an
    // "shell_synced" message. Asset URLs in the shell are
    // content-hashed, so any new CSS/JS the fresh HTML references will
    // also get fetched + cached on demand below.
    evt.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const cached = await cache.match(url.pathname);

      const revalidate = (async () => {
        try {
          const fresh = await fetch(req, { cache: "no-store" });
          if (fresh && fresh.ok && fresh.type !== "opaqueredirect") {
            const clone = fresh.clone();
            await cache.put(url.pathname, fresh.clone());
            const html = await clone.text();
            await warmShellAssets(cache, html, url.toString());
            await broadcastToClients({ kind: "shell_synced", path: url.pathname });
          }
        } catch (e) {
          await broadcastToClients({ kind: "shell_sync_failed", path: url.pathname });
        }
      })();
      evt.waitUntil(revalidate);

      if (cached) return cached;
      // First visit ever (no cache yet) — fall through to network so we
      // have something to render.
      return (await revalidate, fetch(req).catch(() =>
        new Response("offline — shell not yet cached", { status: 503 })));
    })());
    return;
  }

  if (isStaticAsset(url)) {
    evt.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      if (hit) return hit;
      const fresh = await fetch(req).catch(() => null);
      if (fresh && fresh.ok) cache.put(req, fresh.clone());
      return fresh || new Response("offline", { status: 503 });
    })());
    return;
  }

  // JSON / GET fallthrough: network-first, cache fallback.
  evt.respondWith((async () => {
    try {
      const res = await fetch(req);
      if (res && res.ok && req.headers.get("Accept")?.includes("application/json")) {
        const cache = await caches.open(CACHE);
        cache.put(req, res.clone());
      }
      return res;
    } catch (e) {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      return hit || new Response("offline", { status: 503 });
    }
  })());
});
