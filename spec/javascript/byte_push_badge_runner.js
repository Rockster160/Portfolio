// Drives the real byte service worker's `push` handler and reports what it did
// to the app-icon badge and the OS notification, as JSON for
// byte_push_badge_spec.rb.
//
// byte_worker.js is a classic worker script, so it's evaluated in a VM with a
// stubbed worker global rather than imported. The point is to run the handler
// that actually ships: the bug being pinned down here was one of ORDER — the
// badge was written before the foreground check that everything else respected.
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const source = readFileSync(new URL("../../public/byte_worker.js", import.meta.url), "utf8");

// Runs one push against a given set of open windows and returns what the
// handler did.
async function push({ payload, clients }) {
  const listeners = {};
  const acted = { badgeSet: null, badgeCleared: false, notified: null };

  const sandbox = {
    self: {
      addEventListener: (name, fn) => {
        listeners[name] = fn;
      },
      skipWaiting: () => {},
      clients: { matchAll: async () => clients },
      registration: {
        showNotification: async (title, data) => {
          acted.notified = { title, body: data?.body || null };
        },
        getNotifications: async () => [],
      },
    },
    navigator: {
      setAppBadge: (n) => {
        acted.badgeSet = n;
      },
      clearAppBadge: () => {
        acted.badgeCleared = true;
      },
    },
    location: { origin: "https://byte.ardesian.com" },
    caches: { open: async () => ({ match: async () => null }), keys: async () => [] },
    fetch: async () => ({ ok: false }),
    clients: { claim: () => {} },
    URL,
    console,
  };
  sandbox.globalThis = sandbox;
  createContext(sandbox);
  runInContext(source, sandbox);

  const waits = [];
  listeners.push({
    data: { json: () => payload },
    waitUntil: (p) => waits.push(p),
  });
  await Promise.all(waits);
  return acted;
}

const OPEN = [{ visibilityState: "visible", focused: true }];
const BACKGROUNDED = [{ visibilityState: "hidden", focused: false }];
const NONE = [];

const message = { title: "Kettle's done", body: "", data: { count: 6 } };

const results = {
  // The reported bug: app open, looking at the thread, and the icon still gets
  // stamped with a count that includes what's on screen.
  app_open: await push({ payload: message, clients: OPEN }),
  // A tab that exists but isn't being looked at is not "seeing" anything.
  app_backgrounded: await push({ payload: message, clients: BACKGROUNDED }),
  // Closed is the whole reason the count rides on the push at all.
  app_closed: await push({ payload: message, clients: NONE }),
  // A count of zero has to actively clear, not just decline to set.
  cleared_when_zero: await push({
    payload: { title: "x", data: { count: 0 } },
    clients: NONE,
  }),
  // No count at all reads as zero rather than as NaN.
  no_count: await push({ payload: { title: "x" }, clients: NONE }),
};

console.log(JSON.stringify(results));
