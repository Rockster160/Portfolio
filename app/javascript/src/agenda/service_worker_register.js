// Registers the agenda PWA service worker once per page load when the
// browser supports it. Strictly scope-limited to `/agenda` so it never
// activates on the rest of the app. `updateViaCache: "none"` makes the
// browser bypass its own HTTP cache when re-checking the SW source for
// updates — combined with `expires_in 0` on the server side, that gives
// us deploy-fast SW activations without any manual cache-busting.
//
// No `beforeinstallprompt` handler — browsers ship their own unobtrusive
// install affordance (Chrome's URL-bar button, Safari's Share menu).
// Intercepting and showing a custom prompt would be the annoying pattern
// we don't want.

(function () {
  if (typeof window === "undefined") return;
  if (!("serviceWorker" in navigator)) return;
  if (!window.location.pathname.startsWith("/agenda")) return;

  // `load` (not DOMContentLoaded) so the SW registration doesn't compete
  // with the first-paint render for the network/CPU budget.
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/agenda_sw.js", {
      scope:          "/agenda",
      updateViaCache: "none",
    }).catch((err) => {
      // Don't surface — registration failures are mostly env quirks
      // (private browsing, file:// scope, broken HTTP/2 push). The app
      // still works without the SW; we just lose offline shell caching.
      console.error("[agenda] SW registration failed", err);
    });
  });
})();
