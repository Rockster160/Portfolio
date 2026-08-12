// Drives the home-screen badge module and prints what it asked the platform to
// do, as JSON for app_badge_spec.rb.
//
// `navigator` is stubbed before the import so the module's own guards see it,
// and every call is recorded rather than performed. `document` is stubbed too,
// which is what makes the module install its listeners — the whole point of
// this file is that opening and returning to the app both clear the badge, and
// neither is observable without them.
const calls = [];
const listeners = {};

globalThis.navigator = {
  setAppBadge: (n) => calls.push(["set", n]),
  clearAppBadge: () => calls.push(["clear"]),
};
globalThis.document = {
  visibilityState: "visible",
  addEventListener: (name, fn) => {
    listeners[name] = fn;
  },
};
globalThis.window = {
  addEventListener: (name, fn) => {
    listeners[name] = fn;
  },
};

const { ownAppBadge, repaintAppBadge, paintAppBadge } = await import(
  "../../app/javascript/src/support/app_badge.js"
);

const since = (mark) => calls.slice(mark);
const out = {};

// ---- the default, for every page that has no idea ------------------------
// Importing the module IS the app opening. Nothing else has to happen.
out.on_import = calls.map(([kind]) => kind);

let mark = calls.length;
listeners.visibilitychange?.();
out.on_return_to_foreground = since(mark).map(([kind]) => kind);

mark = calls.length;
globalThis.document.visibilityState = "hidden";
listeners.visibilitychange?.();
out.on_going_to_background = since(mark).map(([kind]) => kind);
globalThis.document.visibilityState = "visible";

mark = calls.length;
listeners.pageshow?.();
out.on_pageshow = since(mark).map(([kind]) => kind);

// ---- a page that knows the number ----------------------------------------
let unread = 3;
mark = calls.length;
ownAppBadge(() => unread);
out.on_claim = since(mark);

// The count is READ each time, not captured — a page whose number changes
// between one foreground and the next has to be able to correct the badge
// upward, not only clear it.
mark = calls.length;
unread = 5;
listeners.visibilitychange?.();
out.claimed_returns_fresh = since(mark);

mark = calls.length;
unread = 0;
listeners.visibilitychange?.();
out.claimed_at_zero = since(mark);

mark = calls.length;
paintAppBadge(0);
paintAppBadge(2);
paintAppBadge(-1);
out.direct = since(mark);

process.stdout.write(JSON.stringify(out));
