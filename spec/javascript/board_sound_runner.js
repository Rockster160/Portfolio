// The board's speaker (buddy/sound.js) playing the notes a task sent, and
// nothing while the board is shushed. Printed as JSON for board_sound_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

// The browser's beeps and the pet's mute are stubbed: the runner flips the
// mute and records every list of notes handed to beeps.
const stubs = {
  name: "stubs",
  setup(build) {
    build.onResolve({ filter: /dashboard\/vars$|\/alarm$/ }, (args) => ({
      path: args.path.endsWith("alarm") ? "alarm" : "vars",
      namespace: "stub",
    }));
    build.onLoad({ filter: /^vars$/, namespace: "stub" }, () => ({
      contents: "export const beeps = (notes) => globalThis.__played.push(notes);",
      loader: "js",
    }));
    build.onLoad({ filter: /^alarm$/, namespace: "stub" }, () => ({
      contents: "export const isBuddyMuted = () => globalThis.__muted;",
      loader: "js",
    }));
  },
};

const built = await esbuild.build({
  stdin: {
    contents: `export { playBoardSound } from "./sound.js";`,
    resolveDir: fileURLToPath(new URL("../../app/javascript/src/pages/byte/buddy/", import.meta.url)),
  },
  bundle: true,
  format: "esm",
  write: false,
  plugins: [stubs],
  logLevel: "silent",
});

const { playBoardSound } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

globalThis.__played = [];
globalThis.__muted = false;
const out = {};

const nap = [[400, 392, 0.9, "sine"], [200, 0, 0, null], [600, 262, 0.87, "sine"]];
playBoardSound(nap);
out.played = [...globalThis.__played];

globalThis.__played = [];
playBoardSound("nap");
playBoardSound([]);
playBoardSound(null);
out.nothing_to_play = [...globalThis.__played];

globalThis.__played = [];
globalThis.__muted = true;
playBoardSound(nap);
out.muted = [...globalThis.__played];

process.stdout.write(JSON.stringify(out, null, 2));
