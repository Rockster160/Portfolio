// The number on an installed PWA's home-screen icon, and the one rule about it:
// OPENING THE APP CLEARS IT. Always, immediately, with no condition attached.
//
// A badge is a claim that something is waiting. The person's only way to answer
// that claim is to open the app, so a badge that survives being opened is a
// badge they cannot get rid of by any means available to them — and it stops
// meaning anything the first time it lies.
//
// Every path that could set one used to be a push handler:
// `byte_worker.js`, `agenda_worker.js`, `whisper_worker.js`, `push_worker.js`
// all call `setAppBadge(data.count)` and nothing else ever wrote the badge
// again. Byte alone had a page-side painter, and it only ran when its unread
// tracker CHANGED — so a badge stamped by a push while the app was closed was
// never repainted on the way in, because arriving at zero unread is not a
// change from zero unread. Prod: a 1 that outlived every message it counted.
//
// So the default here is unconditional: on load, and on every return from the
// background, the badge goes to zero. A page that actually knows the number
// (Byte, which tracks unread per conversation) calls `ownAppBadge` and its
// count is used instead — still repainted at those same moments, so it can
// correct the badge upward as well as clear it.

// Set by whichever page has a real number. Null means "nobody knows, so
// nothing is waiting", which is the right answer everywhere else: those pages
// have no unread concept at all, and the badge on them can only be a leftover.
let counter = null;

export function paintAppBadge(total) {
  if (typeof navigator === "undefined") return;

  try {
    if (total > 0) navigator.setAppBadge?.(total);
    else navigator.clearAppBadge?.();
  } catch (e) {
    /* unsupported, or denied — only an installed PWA has an icon to stamp */
  }
}

export function repaintAppBadge() {
  paintAppBadge(counter ? counter() : 0);
}

// This page owns the badge: `countFn` is asked for the number whenever the app
// is opened or comes back to the front. Paints immediately, so claiming it is
// also the first correction.
export function ownAppBadge(countFn) {
  counter = countFn;
  repaintAppBadge();
}

// `visibilitychange` is the one that matters on a phone: a PWA is almost never
// loaded fresh, it's swiped back to. `pageshow` covers a restore from the
// back/forward cache, where no load event fires either.
if (typeof document !== "undefined") {
  repaintAppBadge();

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") repaintAppBadge();
  });
  window.addEventListener("pageshow", repaintAppBadge);
}
