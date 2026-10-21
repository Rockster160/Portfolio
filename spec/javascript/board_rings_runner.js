// The board's status rings (buddy/rings.js) doing what each ring's broadcast
// says and nothing keyed to what it's for: a ring's `sound` when it runs out,
// a `hush` greying the others and holding their sounds, a `color` kept through
// it. Printed as JSON for board_rings_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

// The feed and the speaker are stubbed: the runner plays the broadcasts itself
// and records the tunes.
const stubs = {
  name: "stubs",
  setup(build) {
    build.onResolve({ filter: /cells\/monitor$|\/sound$/ }, (args) => ({
      path: args.path.endsWith("sound") ? "sound" : "monitor",
      namespace: "stub",
    }));
    build.onLoad({ filter: /^sound$/, namespace: "stub" }, () => ({
      contents: "export const playBoardSound = (key) => globalThis.__played.push(key);",
      loader: "js",
    }));
    build.onLoad({ filter: /^monitor$/, namespace: "stub" }, () => ({
      contents: `
        export const Monitor = {
          subscribe: (channel, mixin) => {
            globalThis.__channel = channel;
            globalThis.__feed = mixin;
            return { refresh: () => { globalThis.__refreshes += 1; } };
          },
        };
      `,
      loader: "js",
    }));
  },
};

const built = await esbuild.build({
  stdin: {
    contents: `export { initBoardRings } from "./rings.js";`,
    resolveDir: fileURLToPath(new URL("../../app/javascript/src/pages/byte/buddy/", import.meta.url)),
  },
  bundle: true,
  format: "esm",
  write: false,
  plugins: [stubs],
  logLevel: "silent",
});

globalThis.__played = [];
globalThis.__refreshes = 0;
globalThis.setInterval = () => 0;
globalThis.clearInterval = () => {};

function fakeEl() {
  const classes = new Set();
  const style = {};
  const el = {
    hidden: true,
    dataset: {},
    children: [],
    innerHTML: "",
    textContent: "",
    style: { setProperty: (k, v) => { style[k] = v; }, removeProperty: (k) => delete style[k], values: style },
    classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)), has: (c) => classes.has(c) },
    setAttribute() {},
    querySelector: (sel) => {
      const key = sel.match(/data-duration-key="([^"]+)"/)?.[1];
      if (key) return el.children.find((c) => c.dataset.durationKey === key) || null;
      return null;
    },
    querySelectorAll: () => [...el.children],
    appendChild(child) {
      el.children.push(child);
      child.remove = () => el.children.splice(el.children.indexOf(child), 1);
    },
    insertBefore(child) {
      el.appendChild(child);
    },
  };
  return el;
}
globalThis.document = { createElement: () => fakeEl() };

const { initBoardRings } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

const container = fakeEl();
const app = { dataset: { boardTags: JSON.stringify(["Whisper"]), boardOwnerId: "1" } };
initBoardRings({ container, app });

const now = Math.floor(Date.now() / 1000);
const send = (timers, groups = ["Whisper"]) => globalThis.__feed.received({ owner_id: 1, data: { groups, timers } });
const ring = (key) => container.children.find((c) => c.dataset.durationKey === key);
const out = { channel: globalThis.__channel };

// Two rings run out: only the one that names a sound plays it.
send([
  { key: "a", last: now - 600, next: now - 5, sound: "nap" },
  { key: "b", last: now - 600, next: now - 5 },
]);
out.overdue_played = [...globalThis.__played];

// A hush starts: the others grey (but not one with its own colour, nor the
// hush itself), and a newly overdue sound waits.
globalThis.__played = [];
send([
  { key: "a", last: now - 600, next: now - 5, sound: "nap" },
  { key: "c", last: now - 600, next: now - 5, sound: "wake" },
  { key: "hush", last: now, next: now + 600, hush: true },
  { key: "own", last: now, next: now + 300, color: "#800000" },
]);
out.hushed = {
  a: ring("a").classList.has("quieted"),
  hush: ring("hush").classList.has("quieted"),
  own: ring("own").classList.has("quieted"),
  own_color: ring("own").style.values["--ring-color"],
  own_flag: ring("own").dataset.ringColor,
  played: [...globalThis.__played],
};

// The hush ends: the feed is asked again, the colour goes with the ring.
send([{ key: "a", last: now - 600, next: now - 5, sound: "nap" }, { key: "own", last: now, next: now + 300 }]);
out.after_hush = {
  refreshes: globalThis.__refreshes,
  a: ring("a").classList.has("quieted"),
  own_flag: ring("own").dataset.ringColor || null,
};

// A feed aimed elsewhere shows nothing here.
send([{ key: "a", last: now, next: now + 60 }], ["Garage"]);
out.elsewhere = { rings: container.children.length, hidden: container.hidden };

process.stdout.write(JSON.stringify(out, null, 2));
