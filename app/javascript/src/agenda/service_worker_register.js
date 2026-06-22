// Registers the agenda PWA service worker once per page load when the
// browser supports it. Strictly scope-limited to `/agenda` so it never
// activates on the rest of the app. `updateViaCache: "none"` makes the
// browser bypass its own HTTP cache when re-checking the SW source for
// updates — combined with `expires_in 0` on the server side, that gives
// us deploy-fast SW activations without any manual cache-busting.
//
// Beyond registration, this module also drives the `data-sw-version`
// badge in the page header. The badge starts in `.stale` styling
// (server-rendered) showing the last known cache version from
// localStorage; once the live SW broadcasts its version via
// `{action: "get_version"}` → `{kind: "sw_version", cache}` we drop the
// stale class and write the fresh value. Mirrors the Chores PWA pattern.
//
// No `beforeinstallprompt` handler — browsers ship their own unobtrusive
// install affordance (Chrome's URL-bar button, Safari's Share menu).

(function () {
  if (typeof window === "undefined") return;
  if (!("serviceWorker" in navigator)) return;
  if (!window.location.pathname.startsWith("/agenda")) return;

  const SW_VERSION_KEY = "agenda:sw_version:v1";

  function paintSwVersion(v, stale) {
    document.querySelectorAll("[data-sw-version]").forEach((el) => {
      el.textContent = v || "—";
      el.classList.toggle("stale", !!stale && !!v);
    });
  }

  function requestSwVersion() {
    const ctrl = navigator.serviceWorker.controller;
    if (!ctrl) return;
    try { ctrl.postMessage({ action: "get_version" }); }
    catch (_e) { /* iOS PWA quirk — silently ignored, next event will retry */ }
  }

  // Paint last-known version immediately (still stale) so the badge isn't
  // a blank "—" while the SW boots.
  try {
    const cached = window.localStorage?.getItem(SW_VERSION_KEY);
    if (cached) paintSwVersion(cached, true);
  } catch (_e) { /* localStorage disabled — fine, badge shows "—" */ }

  navigator.serviceWorker.addEventListener("message", (evt) => {
    if (evt.data?.kind !== "sw_version") return;
    const raw = String(evt.data.cache || "");
    // Cache name is `agenda-<sha-or-dev-stamp>` — strip the prefix for
    // display since the "agenda-" part is constant noise.
    const v = raw.replace(/^agenda-/, "") || raw || "—";
    try { window.localStorage?.setItem(SW_VERSION_KEY, v); }
    catch (_e) { /* ignore */ }
    paintSwVersion(v, false);
  });

  // `load` (not DOMContentLoaded) so the SW registration doesn't compete
  // with the first-paint render for the network/CPU budget.
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/agenda_sw.js", {
      scope:          "/agenda",
      updateViaCache: "none",
    }).then((reg) => {
      // Nudge the browser to re-check the SW source on every load. Combined
      // with `updateViaCache: "none"` + `expires_in 0` on the server side,
      // this is what makes a deploy land within one nav.
      try { reg.update(); } catch (_e) {}
      requestSwVersion();
    }).catch((err) => {
      // Don't surface — registration failures are mostly env quirks
      // (private browsing, file:// scope, broken HTTP/2 push). The app
      // still works without the SW; we just lose offline shell caching.
      console.error("[agenda] SW registration failed", err);
    });
  });

  // The active SW changes on a deploy (new version installs + skipWaiting +
  // clients.claim). Re-ask for the version so the badge updates instantly
  // instead of waiting for the next page load.
  navigator.serviceWorker.addEventListener("controllerchange", requestSwVersion);
})();
