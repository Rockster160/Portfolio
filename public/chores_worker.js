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
const CACHE = "chores-v87";

// Last-resort: any real cached shell is better than no page at all.
// If the user requested e.g. /chores (Grid) but only /chores/today
// is in cache, serving today's shell still gives them the real chores
// UI which hydrates from localStorage and lets them keep using the
// app. The viewer's `setActiveView` resolves the active view from
// the current URL on boot, so the rendered tab will reflect what the
// user actually asked for once JS runs.
async function anyCachedShell() {
  const cache = await caches.open(CACHE);
  for (const p of SHELL_PATHS) {
    const hit = await cache.match(p);
    if (hit) return hit;
  }
  for (const p of SHELL_PATHS) {
    const old = await matchFromOldCaches(p);
    if (old) return old;
  }
  return null;
}
// Every chore view is a cached shell. Each shell is body-empty for
// page-specific content — entries on History, recent rows on Balance —
// because that data is hydrated client-side from JSON (and from a
// localStorage cache for instant repeat visits). The shell load itself
// is offline-tolerant; the JSON fetches degrade gracefully when there
// is no connection.
const SHELL_PATHS = [
  "/chores",
  "/chores/today",
  "/chores/balance",
  "/chores/history",
];

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

// Cheap structural validation: the real chores shell always carries
// `<meta name="chores-shell" content="ok">` (added in page.html.erb's
// head content_for block). A 200 OK that isn't actually our shell —
// a wrong-controller render, an error page, an auth interstitial that
// didn't redirect — won't have it. We refuse to write the response
// into the cache when the marker is missing, preserving the previous
// (working) shell. The check is HTML-substring, not DOM-parsed, so
// it runs fast inside the SW without spinning up a parser.
const SHELL_MARKER = '<meta name="chores-shell" content="ok">';
function isValidShellBody(html) {
  return typeof html === "string" && html.indexOf(SHELL_MARKER) !== -1;
}

// Parse a shell HTML body for asset URLs the page needs to render and
// warm them into the cache. ATOMIC: returns true only if EVERY
// precachable asset succeeded. The caller uses this to gate writing
// the shell itself — a shell is never cached unless all its assets
// are also in cache. Without this guarantee, a deploy that races with
// a slow CDN, an offline install, or any asset fetch that 404s would
// cache a shell referencing dead URLs → JS fails → blank/black page
// on next boot.
async function warmShellAssets(cache, shellHtml, baseUrl) {
  const urls = new Set();
  const re = /\b(?:src|href)=["']([^"']+)["']/g;
  let m;
  while ((m = re.exec(shellHtml)) !== null) {
    let u;
    try {
      u = new URL(m[1], baseUrl);
    } catch (e) {
      continue;
    }
    if (isPrecachableAssetURL(u)) urls.add(u.toString());
  }
  const results = await Promise.all(
    Array.from(urls).map(async (u) => {
      try {
        const existing = await cache.match(u);
        if (existing) return true;
        const r = await fetch(u, {
          credentials: "same-origin",
          cache: "no-store",
        });
        if (!r || !r.ok) return false;
        await cache.put(u, r.clone());
        return true;
      } catch (e) {
        return false;
      }
    }),
  );
  return results.every(Boolean);
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
  await Promise.all(
    SHELL_PATHS.map(async (p) => {
      try {
        const r = await fetch(p, {
          credentials: "same-origin",
          redirect: "manual",
          cache: "no-store",
        });
        if (!r || !r.ok || r.type === "opaqueredirect") {
          await broadcastToClients({ kind: "shell_sync_failed", path: p });
          return;
        }
        const clone = r.clone();
        const html = await clone.text();
        // Validate FIRST. A 200 OK that doesn't carry the
        // chores-shell meta marker is not our shell (error page,
        // wrong controller, auth interstitial). Reject before any
        // cache write — the previous good shell stays live.
        if (!isValidShellBody(html)) {
          await broadcastToClients({ kind: "shell_sync_failed", path: p });
          return;
        }
        // Warm assets next. Only if every referenced asset is now in
        // cache do we replace the shell entry. A failed asset fetch
        // means the previous (working) shell + assets stay live —
        // never serve a shell whose JS/CSS won't load.
        const assetsOk = await warmShellAssets(
          cache,
          html,
          new URL(p, location.origin).toString(),
        );
        if (!assetsOk) {
          await broadcastToClients({ kind: "shell_sync_failed", path: p });
          return;
        }
        await cache.put(p, r.clone());
        await broadcastToClients({ kind: "shell_synced", path: p });
      } catch (e) {
        await broadcastToClients({ kind: "shell_sync_failed", path: p });
      }
    }),
  );
}

// Hard verification that EVERY shell path + every asset URL referenced
// inside those shells is sitting in the current cache. The page-script
// uses this to decide whether it's safe to expose a "tap to reload"
// indicator: only when this returns ok can the user reload without
// risk of landing on a half-cached deploy (missing CSS/JS → black
// screen, broken offline boot). Returns { ok: true } or
// { ok: false, reason }.
async function verifyShellReady() {
  const cache = await caches.open(CACHE);
  for (const p of SHELL_PATHS) {
    const shellResp = await cache.match(p);
    if (!shellResp) return { ok: false, reason: `missing shell ${p}` };
    const html = await shellResp.clone().text();
    const re = /\b(?:src|href)=["']([^"']+)["']/g;
    let m;
    while ((m = re.exec(html)) !== null) {
      let u;
      try {
        u = new URL(m[1], new URL(p, location.origin));
      } catch (e) {
        continue;
      }
      if (!isPrecachableAssetURL(u)) continue;
      const hit = await cache.match(u.toString());
      if (!hit) return { ok: false, reason: `missing asset ${u.pathname}` };
    }
  }
  return { ok: true };
}

// Web Push handler. Mirrors agenda_worker.js — payload is the JSON the
// server sends to WebPush.payload_send (title/body/icon/tag/data).
// `dismiss: true` with a tag short-circuits to closing any active
// notification with that tag (e.g. when work is undone elsewhere).
self.addEventListener("push", (evt) => {
  let data = {};
  try {
    data = evt.data ? evt.data.json() : {};
  } catch (_e) {
    return;
  }

  if (data.dismiss && data.tag) {
    evt.waitUntil(
      self.registration
        .getNotifications({ tag: data.tag })
        .then((list) => list.forEach((n) => n.close())),
    );
    return;
  }

  data.icon = data.icon || "/favicon/android-chrome-192x192.png";
  if (data.title || data.body) {
    evt.waitUntil(
      self.registration.showNotification(data.title || "Chores", data),
    );
  }
});

self.addEventListener("notificationclick", (evt) => {
  evt.notification.close();
  const targetUrl = evt.notification.data?.url || "/chores";
  evt.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({
        type: "window",
        includeUncontrolled: true,
      });
      for (const c of all) {
        const url = new URL(c.url);
        if (url.pathname.startsWith("/chores") && "focus" in c) {
          if (c.url !== targetUrl && "navigate" in c) {
            await c.navigate(targetUrl);
          }
          return c.focus();
        }
      }
      if (self.clients.openWindow) await self.clients.openWindow(targetUrl);
    })(),
  );
});

self.addEventListener("message", (evt) => {
  if (evt.data?.action === "refresh_shells") {
    evt.waitUntil(refreshAllShells());
  }
  if (evt.data?.action === "get_version") {
    // Broadcast rather than reply via a transferred MessagePort:
    // port-based round-trips from a SW silently drop in some iOS PWA
    // contexts, leaving the page stuck thinking the SW never answered.
    // A broadcast hits the page's existing message listener reliably.
    evt.waitUntil(broadcastToClients({ kind: "sw_version", cache: CACHE }));
  }
  if (evt.data?.action === "verify_ready") {
    const port = evt.ports?.[0];
    evt.waitUntil(
      (async () => {
        let result;
        try {
          result = await verifyShellReady();
          if (!result.ok) {
            // One retry: maybe the install raced and missed something.
            // Force a clean refresh, then re-verify. If still not ok,
            // the page-script will retry on the next visibility change.
            await refreshAllShells();
            result = await verifyShellReady();
          }
        } catch (e) {
          result = { ok: false, reason: `verify threw: ${e?.message || e}` };
        }
        port?.postMessage(result);
      })(),
    );
  }
});

async function broadcastToClients(payload) {
  const clients = await self.clients.matchAll({ includeUncontrolled: true });
  clients.forEach((c) => c.postMessage(payload));
}

// Look in every other chores-* cache for a request/path. Used as a
// last-resort fallback when the current cache hasn't been populated yet
// (e.g. a flaky install) so the previous deploy's cache still serves.
async function matchFromOldCaches(reqOrPath) {
  const keys = await caches.keys();
  for (const k of keys) {
    if (k === CACHE || !k.startsWith("chores-")) continue;
    const c = await caches.open(k);
    const hit = await c.match(reqOrPath);
    if (hit) return hit;
  }
  return null;
}

self.addEventListener("install", (evt) => {
  evt.waitUntil(refreshAllShells());
  self.skipWaiting();
});

self.addEventListener("activate", (evt) => {
  evt.waitUntil(
    (async () => {
      const newCache = await caches.open(CACHE);
      // Only purge old chores-* caches when the new cache actually has at
      // least one shell populated. An offline/flaky install would leave
      // the new cache empty; if we deleted the previous cache eagerly the
      // next visit would have NOTHING to serve and the page would render
      // as a black/blank screen.
      let hasShell = false;
      for (const p of SHELL_PATHS) {
        if (await newCache.match(p)) {
          hasShell = true;
          break;
        }
      }
      if (hasShell) {
        const keys = await caches.keys();
        await Promise.all(
          keys
            .filter((k) => k.startsWith("chores-") && k !== CACHE)
            .map((k) => caches.delete(k)),
        );
      }
      await self.clients.claim();
    })(),
  );
});

// Query params that are launch/analytics only and do not change which
// shell to serve. The PWA manifest's `start_url` carries `?source=pwa`,
// so without this allow-list the very first request a PWA makes on
// every launch would bypass the cache entirely (and offline would fall
// through to a 503 plain-text "offline" response — the exact grey/text
// screen we are here to prevent).
const SHELL_PASSTHROUGH_PARAMS = new Set([
  "source",
  "utm_source",
  "utm_medium",
  "utm_campaign",
]);
function isShellRequest(url) {
  // History is excluded above from SHELL_PATHS entirely. The remaining
  // shells (Grid / Today / Balance) are not paginated. Allow only
  // launch/analytics params through; any other query string is treated
  // as a non-shell GET and falls through to the network.
  if (!SHELL_PATHS.includes(url.pathname)) return false;
  for (const k of url.searchParams.keys()) {
    if (!SHELL_PASSTHROUGH_PARAMS.has(k)) return false;
  }
  return true;
}

function isStaticAsset(url) {
  return (
    url.pathname.startsWith("/assets/") ||
    url.pathname.startsWith("/whisper_favicon/") ||
    url.pathname.endsWith(".webmanifest")
  );
}

self.addEventListener("fetch", (evt) => {
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
    evt.respondWith(
      (async () => {
        const cache = await caches.open(CACHE);
        let cached = await cache.match(url.pathname);
        // Defense in depth: an install that finished offline can leave
        // the current cache empty even after activate has run. Fall back
        // to any older chores-* cache so the user still sees the last
        // shell they had instead of a 503/blank page.
        if (!cached) cached = await matchFromOldCaches(url.pathname);

        const revalidate = (async () => {
          try {
            const fresh = await fetch(req, { cache: "no-store" });
            if (!fresh || !fresh.ok || fresh.type === "opaqueredirect") return;
            const clone = fresh.clone();
            const html = await clone.text();
            // Validate the response carries the chores-shell marker
            // before doing anything cache-side. Stops a 200 OK that
            // isn't actually our shell from ever reaching cache.put.
            if (!isValidShellBody(html)) {
              await broadcastToClients({
                kind: "shell_sync_failed",
                path: url.pathname,
              });
              return;
            }
            // Same atomic rule as install/refresh: only replace the
            // cached shell after every referenced asset is cached.
            const assetsOk = await warmShellAssets(cache, html, url.toString());
            if (!assetsOk) {
              await broadcastToClients({
                kind: "shell_sync_failed",
                path: url.pathname,
              });
              return;
            }
            await cache.put(url.pathname, fresh.clone());
            await broadcastToClients({
              kind: "shell_synced",
              path: url.pathname,
            });
          } catch (e) {
            await broadcastToClients({
              kind: "shell_sync_failed",
              path: url.pathname,
            });
          }
        })();
        evt.waitUntil(revalidate);

        if (cached) return cached;
        // No shell cached at this exact path — fall through to network
        // so we have something to render. If the network also fails,
        // serve ANY other cached shell rather than a 503/blank page.
        // The page-script's view router resolves the active tab from
        // location.pathname once JS runs, so the user lands on the
        // right tab even when we hand them a sibling shell's HTML.
        await revalidate;
        try {
          const net = await fetch(req);
          if (net && (net.ok || net.type === "opaque")) return net;
        } catch (e) {}
        const anyShell = await anyCachedShell();
        if (anyShell) return anyShell;
        // Truly nothing cached anywhere (first-ever install with no
        // network). Re-throw by re-attempting the fetch so the browser
        // shows its native "no internet" page rather than a synthetic
        // placeholder we'd have to invent.
        return fetch(req);
      })(),
    );
    return;
  }

  if (isStaticAsset(url)) {
    evt.respondWith(
      (async () => {
        const cache = await caches.open(CACHE);
        const hit = await cache.match(req);
        if (hit) return hit;
        // Older content-hashed asset might still live in a prior cache —
        // use it offline so a page served from an old shell still has
        // its CSS/JS instead of dropping to an unstyled black render.
        const fallback = await matchFromOldCaches(req);
        const fresh = await fetch(req).catch(() => null);
        if (fresh && fresh.ok) cache.put(req, fresh.clone());
        return fresh || fallback || new Response("offline", { status: 503 });
      })(),
    );
    return;
  }

  // JSON / GET fallthrough: network-first, cache fallback.
  evt.respondWith(
    (async () => {
      try {
        const res = await fetch(req);
        if (
          res &&
          res.ok &&
          req.headers.get("Accept")?.includes("application/json")
        ) {
          const cache = await caches.open(CACHE);
          cache.put(req, res.clone());
        }
        return res;
      } catch (e) {
        const cache = await caches.open(CACHE);
        const hit = await cache.match(req);
        if (hit) return hit;
        // Page navigations that aren't shell paths (e.g. a deep link
        // under /chores that fell through) should still land on the
        // real chores UI, not a bare 503. Serve any cached shell.
        if (req.mode === "navigate") {
          const anyShell = await anyCachedShell();
          if (anyShell) return anyShell;
        }
        return new Response("offline", { status: 503 });
      }
    })(),
  );
});
