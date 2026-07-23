// Byte service worker.
//
// Strategy (adapted from chores_worker.js):
//   * App shell HTML → stale-while-revalidate. PWA boots from cache with
//     zero reception; a background fetch quietly replaces the cached
//     shell for next load.
//   * Static assets (built JS/CSS, manifest, icons) → cache-first.
//   * POST /byte/messages → never served by SW. The page script has its
//     own localStorage outbound queue and retries on `online` / focus.
//   * Other GETs (/byte/messages history, etc.) → network-first with
//     cache fallback.
//
// Cache name is versioned: bump CACHE on shipping a new shell so old
// clients re-pull the HTML next time they're online.

const CACHE = "byte-v4";

// Byte only has one shell: the root of byte.<host>. Extending this list
// later (a settings screen, a per-thread view, etc.) is a matter of
// adding paths and giving each shell the shell marker.
const SHELL_PATHS = ["/"];

// Cheap structural validation: the real byte shell always carries
// `<meta name="byte-shell" content="ok">` (rendered from show.html.erb).
// A 200 OK that isn't actually our shell — a wrong-controller render,
// an error page, an auth interstitial — won't have it. We refuse to
// write the response into cache when the marker is missing, preserving
// the previous (working) shell.
const SHELL_MARKER = '<meta name="byte-shell" content="ok">';
function isValidShellBody(html) {
  return typeof html === "string" && html.indexOf(SHELL_MARKER) !== -1;
}

// Extract the deploy version stamped in every server-rendered shell:
//   <meta name="byte-version" content="<COMMIT_SHA>">
// Two versions that DIFFER = a real deploy landed and this cached page
// is now outdated. Two versions that MATCH = server render is the same
// build, even if the surrounding HTML differs (bootstrap JSON, timestamps).
const VERSION_RE = /<meta\s+name=["']byte-version["']\s+content=["']([^"']+)["']/i;
function extractShellVersion(html) {
  if (typeof html !== "string") return null;
  const m = html.match(VERSION_RE);
  return m ? m[1] : null;
}

// Same-origin, precachable assets: built bundles, our own icons/manifest.
// Anything else (cross-origin, API endpoints, opaque resources) is
// intentionally skipped.
function isPrecachableAssetURL(url) {
  if (url.origin !== location.origin) return false;
  if (url.pathname.startsWith("/assets/")) return true;
  if (url.pathname.startsWith("/byte_favicon/")) return true;
  if (url.pathname.endsWith(".webmanifest")) return true;
  return false;
}

// Parse a shell HTML body for asset URLs and warm them into the cache.
// ATOMIC: returns true only if EVERY precachable asset succeeded. The
// caller uses this to gate writing the shell itself — a shell is never
// cached unless all its assets are also in cache. Without this, a deploy
// that races with a slow CDN, an offline install, or any asset fetch that
// 404s would cache a shell referencing dead URLs → JS fails → black page
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
        const r = await fetch(u, { credentials: "same-origin", cache: "no-store" });
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

// Background shell refresh — fired on install, on message-channel
// requests from the page script, and on stale-while-revalidate fetches.
async function refreshAllShells() {
  const cache = await caches.open(CACHE);
  await Promise.all(
    SHELL_PATHS.map(async (p) => {
      try {
        // Read the current cached shell FIRST so we can tell "revalidated
        // to the same build" (shell_synced) from "revalidated to a new
        // deploy" (shell_updated).
        const priorResp = await cache.match(p);
        const priorVersion = priorResp ? extractShellVersion(await priorResp.clone().text()) : null;

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
        if (!isValidShellBody(html)) {
          await broadcastToClients({ kind: "shell_sync_failed", path: p });
          return;
        }
        const assetsOk = await warmShellAssets(cache, html, new URL(p, location.origin).toString());
        if (!assetsOk) {
          await broadcastToClients({ kind: "shell_sync_failed", path: p });
          return;
        }
        await cache.put(p, r.clone());
        // Compare deploy versions, not raw HTML. The bootstrap JSON in
        // the shell changes on every request; comparing versions makes
        // shell_updated fire ONLY when a real deploy has landed.
        const newVersion = extractShellVersion(html);
        if (priorVersion && newVersion && priorVersion !== newVersion) {
          await broadcastToClients({ kind: "shell_updated", path: p });
        } else {
          await broadcastToClients({ kind: "shell_synced", path: p });
        }
      } catch (e) {
        await broadcastToClients({ kind: "shell_sync_failed", path: p });
      }
    }),
  );
}

// Hard verification the current cache is complete: every shell path AND
// every referenced asset must be present. Page script uses this before
// showing a "safe to reload" indicator.
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

async function matchFromOldCaches(reqOrPath) {
  const keys = await caches.keys();
  for (const k of keys) {
    if (k === CACHE || !k.startsWith("byte-")) continue;
    const c = await caches.open(k);
    const hit = await c.match(reqOrPath);
    if (hit) return hit;
  }
  return null;
}

async function broadcastToClients(payload) {
  const clients = await self.clients.matchAll({ includeUncontrolled: true });
  clients.forEach((c) => c.postMessage(payload));
}

// -------- Push notifications --------

self.addEventListener("push", (evt) => {
  let data = {};
  try {
    data = evt.data ? evt.data.json() : {};
  } catch (e) {
    return;
  }

  if (data.dismiss && data.tag) {
    evt.waitUntil(
      self.registration.getNotifications({ tag: data.tag }).then((notes) => {
        notes.forEach((n) => n.close());
      }),
    );
    return;
  }

  data.icon = data.icon || "/byte_favicon/byte-detail.png";
  data.badge = data.badge || "/byte_favicon/byte-detail.png";

  const badgeCount = parseInt(data.data?.count || 0);
  if (navigator.setAppBadge) {
    if (badgeCount > 0) navigator.setAppBadge(badgeCount);
    else navigator.clearAppBadge();
  }

  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title || "Byte", data));
  }
});

self.addEventListener("notificationclick", (evt) => {
  evt.notification.close();
  const targetUrl = evt.notification.data?.url || "/";

  evt.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const c of all) {
        if (c.url.includes("byte") && "focus" in c) return c.focus();
      }
      if (self.clients.openWindow) await self.clients.openWindow(targetUrl);
    })(),
  );
});

// -------- Message channel (coordination with page script) --------

self.addEventListener("message", (evt) => {
  if (evt.data?.action === "refresh_shells") {
    evt.waitUntil(refreshAllShells());
  }
  if (evt.data?.action === "skip_waiting") {
    self.skipWaiting();
  }
  if (evt.data?.action === "get_version") {
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

// -------- Lifecycle --------

self.addEventListener("install", (evt) => {
  evt.waitUntil(refreshAllShells());
  self.skipWaiting();
});

self.addEventListener("activate", (evt) => {
  evt.waitUntil(
    (async () => {
      const newCache = await caches.open(CACHE);
      let hasShell = false;
      for (const p of SHELL_PATHS) {
        if (await newCache.match(p)) { hasShell = true; break; }
      }
      if (hasShell) {
        const keys = await caches.keys();
        await Promise.all(
          keys.filter((k) => k.startsWith("byte-") && k !== CACHE).map((k) => caches.delete(k)),
        );
      }
      await self.clients.claim();
    })(),
  );
});

// -------- Fetch handler --------

const SHELL_PASSTHROUGH_PARAMS = new Set([
  "source",
  "utm_source",
  "utm_medium",
  "utm_campaign",
]);

function isShellRequest(url) {
  if (!SHELL_PATHS.includes(url.pathname)) return false;
  for (const k of url.searchParams.keys()) {
    if (!SHELL_PASSTHROUGH_PARAMS.has(k)) return false;
  }
  return true;
}

function isStaticAsset(url) {
  return (
    url.pathname.startsWith("/assets/") ||
    url.pathname.startsWith("/byte_favicon/") ||
    url.pathname.endsWith(".webmanifest")
  );
}

self.addEventListener("fetch", (evt) => {
  const req = evt.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  if (url.origin !== location.origin) return;

  if (isShellRequest(url)) {
    evt.respondWith(
      (async () => {
        const cache = await caches.open(CACHE);
        let cached = await cache.match(url.pathname);
        if (!cached) cached = await matchFromOldCaches(url.pathname);

        const revalidate = (async () => {
          try {
            // Re-read the current cache entry at the top of revalidate so
            // we compare against whatever's already in cache (which may
            // have been updated by a prior in-flight revalidate).
            const currentCached = await cache.match(url.pathname);
            const priorVersion = currentCached ? extractShellVersion(await currentCached.clone().text()) : null;
            const fresh = await fetch(req, { cache: "no-store" });
            if (!fresh || !fresh.ok || fresh.type === "opaqueredirect") return;
            const clone = fresh.clone();
            const html = await clone.text();
            if (!isValidShellBody(html)) {
              await broadcastToClients({ kind: "shell_sync_failed", path: url.pathname });
              return;
            }
            const assetsOk = await warmShellAssets(cache, html, url.toString());
            if (!assetsOk) {
              await broadcastToClients({ kind: "shell_sync_failed", path: url.pathname });
              return;
            }
            await cache.put(url.pathname, fresh.clone());
            const newVersion = extractShellVersion(html);
            if (priorVersion && newVersion && priorVersion !== newVersion) {
              await broadcastToClients({ kind: "shell_updated", path: url.pathname });
            } else {
              await broadcastToClients({ kind: "shell_synced", path: url.pathname });
            }
          } catch (e) {
            await broadcastToClients({ kind: "shell_sync_failed", path: url.pathname });
          }
        })();
        evt.waitUntil(revalidate);

        if (cached) return cached;
        await revalidate;
        try {
          const net = await fetch(req);
          if (net && (net.ok || net.type === "opaque")) return net;
        } catch (e) {}
        const anyShell = await anyCachedShell();
        if (anyShell) return anyShell;
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
        if (res && res.ok && req.headers.get("Accept")?.includes("application/json")) {
          const cache = await caches.open(CACHE);
          cache.put(req, res.clone());
        }
        return res;
      } catch (e) {
        const cache = await caches.open(CACHE);
        const hit = await cache.match(req);
        if (hit) return hit;
        if (req.mode === "navigate") {
          const anyShell = await anyCachedShell();
          if (anyShell) return anyShell;
        }
        return new Response("offline", { status: 503 });
      }
    })(),
  );
});
