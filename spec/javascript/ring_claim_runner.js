// One sound per ring running out (buddy/ring_claim.js), however many screens
// are showing it: two screens, a reload, the five-minute repeat, a hidden page,
// and a claim server that can't be reached. Printed as JSON for
// ring_claim_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

const built = await esbuild.build({
  stdin: {
    contents: `export * from "./ring_claim.js";`,
    resolveDir: fileURLToPath(new URL("../../app/javascript/src/pages/byte/buddy/", import.meta.url)),
  },
  bundle: true,
  format: "esm",
  write: false,
  logLevel: "silent",
});
const source = "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64");
// Each import with its own suffix is a fresh module: a separate screen, or the
// same screen after a reload.
let screens = 0;
const screen = () => import(`${source}#${(screens += 1)}`);

const claimed = new Set();
let serverUp = true;
let claims = 0;
globalThis.fetch = async (_url, opts) => {
  claims += 1;
  if (!serverUp) throw new Error("offline");
  const b = JSON.parse(opts.body);
  const id = `${b.owner_id}:${b.key}:${b.at}:${b.slot}`;
  const play = !claimed.has(id);
  claimed.add(id);
  return { ok: true, json: async () => ({ play }) };
};

// One device's storage, shared by every screen built on it.
const store = {};
globalThis.window = {
  localStorage: { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = v; } },
};
globalThis.document = { visibilityState: "visible" };
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

const now = 1_000_000;
const t0 = Date.now();
let played = [];
const ring = (mod, next, nowSec, nowMs = t0, key = "wake") =>
  mod.soundOnce({ ownerId: 1, key, next, nowSec }, () => played.push(`${key}@${nowSec - next}`), nowMs);
const out = {};

// Two screens see the same ring run out, each ticking every second.
const wall = await screen();
const phone = await screen();
for (let s = 0; s < 3; s++) {
  ring(wall, now, now + s);
  ring(phone, now, now + s);
  await settle();
}
out.two_screens = [...played];

// The wall reloads while it is still overdue.
played = [];
const reloaded = await screen();
ring(reloaded, now, now + 20);
await settle();
out.after_reload = [...played];

// Five minutes overdue is the repeat, and it plays once again.
played = [];
ring(reloaded, now, now + 300);
ring(phone, now, now + 301);
await settle();
out.repeat = [...played];

// A ring marked once sounds when it runs out and stays quiet at the repeat.
played = [];
const single = (nowSec) =>
  reloaded.soundOnce(
    { ownerId: 1, key: "nap", next: now, nowSec, once: true },
    () => played.push(`nap@${nowSec - now}`),
  );
single(now);
await settle();
single(now + 300);
single(now + 600);
await settle();
out.once = [...played];

// A hidden page never claims.
played = [];
const before = claims;
globalThis.document.visibilityState = "hidden";
const hidden = await screen();
ring(hidden, now + 1000, now + 1000);
await settle();
globalThis.document.visibilityState = "visible";
out.hidden = { played: [...played], claims: claims - before };

// The wall can't make a sound (reloaded and never tapped) and ticks first: it
// stays out of the claim, and the phone plays. Once it's tapped it can claim.
played = [];
const silentBefore = claims;
const blockedWall = await screen();
const listeningPhone = await screen();
const silentRing = (mod, nowSec, audible) =>
  mod.soundOnce(
    { ownerId: 1, key: "nap", next: now + 2000, nowSec, audible },
    () => played.push(mod === blockedWall ? "wall" : "phone"),
  );
silentRing(blockedWall, now + 2000, false);
await settle();
const wallClaims = claims - silentBefore;
silentRing(listeningPhone, now + 2000, true);
await settle();
silentRing(blockedWall, now + 2300, true);
await settle();
out.silent = { played: [...played], wall_claims_while_silent: wallClaims };

// The server is down: it keeps asking, then plays anyway, once.
played = [];
serverUp = false;
const offline = await screen();
const next = now + 5000;
for (const ms of [0, 1000, 6000, 31000, 32000, 40000]) {
  ring(offline, next, next + Math.floor(ms / 1000), t0 + ms, "nap");
  await settle();
}
out.offline = [...played];

process.stdout.write(JSON.stringify(out, null, 2));
