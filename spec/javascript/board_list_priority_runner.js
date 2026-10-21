// What the pet does about a board list's high and very high items, printed as
// JSON for board_list_priority_spec.rb: the newest high item in its speech
// bubble, the newest very high one in its thought bubble while it shouts (the
// alarm's face flip) until that item is checked off.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

const built = await esbuild.build({
  stdin: {
    contents: `
      export { initBoardDream } from "./dream.js";
      export { initBoardAlert } from "./board_alert";
    `,
    resolveDir: fileURLToPath(new URL("../../app/javascript/src/pages/byte/buddy/", import.meta.url)),
  },
  bundle: true,
  format: "esm",
  write: false,
  logLevel: "silent",
});

// The flip runs on an interval; one tick is enough to see it.
const intervals = new Map();
let nextId = 1;
globalThis.window = {
  setTimeout: () => 0,
  setInterval: (fn) => {
    intervals.set(nextId, fn);
    return nextId++;
  },
};
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.clearInterval = (id) => intervals.delete(id);
globalThis.document = { querySelector: () => null, createElement: () => fakeEl() };

function fakeEl() {
  return {
    hidden: true,
    textContent: "",
    title: "",
    dataset: {},
    children: [],
    classList: { add() {} },
    appendChild(child) {
      this.children.push(child);
      this.textContent += child.textContent || "";
    },
    removeAttribute() {},
  };
}

const { initBoardDream, initBoardAlert } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

const faces = [];
const holds = new Map();
const hero = {
  setExpression: (face, opts) => faces.push([face, !!opts?.transient]),
  holdExpression: (key, face) => holds.set(key, face),
  releaseExpression: (key) => holds.delete(key),
  restExpression: () => faces.push(["rest", false]),
};

const speech = fakeEl();
const thought = fakeEl();
const alert = initBoardAlert({ bubble: speech, hero, tags: ["Garage"] });
const dream = initBoardDream({ bubble: thought, hero, tags: ["Garage"], boardIdFn: () => 61, choreDreams: false });

const item = (id, name, priority, rank, checked = false) => ({
  id, kind: "list", name, short_name: name, icon: null, priority, rank, checked,
});
const feed = (items) => {
  alert.setItems(items);
  dream.setItems(items);
};
const tick = () => intervals.forEach((fn) => fn());
const out = {};

feed([
  item(1, "Cards", "high", 3),
  item(2, "Chairs", "high", 7),
  item(3, "Old one", "high", 9, true),
  item(4, "Table", "normal", 10),
]);
out.high = { speech: speech.textContent, speechHidden: speech.hidden, thoughtHidden: thought.hidden };
out.high_shouts = intervals.size > 0;
out.high_face = holds.get("board-list-high") || null;

feed([item(2, "Chairs", "high", 7), item(5, "Keys", "very_high", 2), item(6, "Wallet", "very_high", 8)]);
tick();
out.very_high = { thought: thought.textContent, thoughtHidden: thought.hidden, speech: speech.textContent };
out.shouting = intervals.size > 0;
out.shout_faces = [...new Set(faces.filter(([, transient]) => transient).map(([face]) => face))].sort();

// The pet is tapped: a shout isn't put away by that.
dream.dismiss(Date.now() + 1000);
out.after_tap = { thought: thought.textContent, shouting: intervals.size > 0 };

feed([item(2, "Chairs", "high", 7), item(6, "Wallet", "very_high", 8, true)]);
out.checked_off = {
  thoughtHidden: thought.hidden,
  shouting: intervals.size > 0,
  rested: faces.at(-1)?.[0] === "rest",
};

feed([]);
out.all_done = { speechHidden: speech.hidden, thoughtHidden: thought.hidden, highFace: holds.get("board-list-high") || null };

process.stdout.write(JSON.stringify(out, null, 2));
