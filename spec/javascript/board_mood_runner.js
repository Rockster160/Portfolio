// What the board does with a mood held from Jil (Buddy.mood): no bubble, and
// the pet holding its face for each pet, under the mood's own key, until it is
// resolved. Printed as JSON for board_mood_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

const built = await esbuild.build({
  stdin: {
    contents: `export { initBoardAlert } from "./board_alert";`,
    resolveDir: fileURLToPath(new URL("../../app/javascript/src/pages/byte/buddy/", import.meta.url)),
  },
  bundle: true,
  format: "esm",
  write: false,
  logLevel: "silent",
});

globalThis.window = { setTimeout: () => 0, setInterval: () => 0 };
globalThis.clearInterval = () => {};

const { initBoardAlert } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

const holds = new Map();
const hero = {
  setExpression: () => {},
  holdExpression: (key, face, strength) => holds.set(key, { face, strength }),
  releaseExpression: (key) => holds.delete(key),
  restExpression: () => {},
};
const bubble = { hidden: true, textContent: "", dataset: {}, removeAttribute() {} };
const alert = initBoardAlert({ bubble, hero, tags: ["whisper"] });

const busy = {
  key: "busy", body: "", board_only: true, groups: ["Whisper"], strength: 60,
  faces: { byte: "nerd", moss: "happy" },
};
const elsewhere = { ...busy, key: "garage", groups: ["Garage"] };
const out = {};

alert.setAlerts([busy, elsewhere]);
out.held = Object.fromEntries(holds);
out.bubbleHidden = bubble.hidden;

alert.setAlerts([
  busy,
  { key: "gate", body: "Gate open", board_only: true, groups: ["Whisper"], faces: { byte: "sleeping" } },
]);
out.with_alert = { bubble: bubble.textContent, held: Object.fromEntries(holds) };

alert.setAlerts([]);
out.resolved = Object.fromEntries(holds);

process.stdout.write(JSON.stringify(out, null, 2));
