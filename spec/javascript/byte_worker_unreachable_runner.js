// Drives the real byte service worker's `fetch` handler for a board with
// nothing cached and no server, and reports what it answered, as JSON for
// byte_worker_unreachable_spec.rb. Evaluated in a VM like byte_push_badge_runner.
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const source = readFileSync(new URL("../../public/byte_worker.js", import.meta.url), "utf8");
const listeners = {};
const emptyCache = { match: async () => null, put: async () => {} };
const sandbox = {
  self: {
    addEventListener: (name, fn) => {
      listeners[name] = fn;
    },
    skipWaiting: () => {},
    clients: { matchAll: async () => [] },
    registration: {},
  },
  navigator: {},
  location: { origin: "https://byte.ardesian.com" },
  caches: { open: async () => emptyCache, keys: async () => [] },
  fetch: async () => {
    throw new TypeError("Failed to fetch");
  },
  clients: { claim: () => {} },
  Response,
  URL,
  console,
};
sandbox.globalThis = sandbox;
createContext(sandbox);
runInContext(source, sandbox);

let answered = null;
listeners.fetch({
  request: { method: "GET", url: "https://byte.ardesian.com/board/61" },
  respondWith: (p) => {
    answered = p;
  },
  waitUntil: () => {},
});
const res = await answered;
const body = await res.text();
process.stdout.write(JSON.stringify({
  status: res.status,
  type: res.headers.get("Content-Type"),
  says: body.includes("Can't reach the server"),
  retries: body.includes("location.reload()"),
}));
