// Searches the shared icon pool the way a picker and a guess each do, against
// the real index files on disk, and prints JSON for icon_pool_characters_spec.rb.

import esbuild from "esbuild";
import fs from "fs";
import { fileURLToPath } from "url";

const root = fileURLToPath(new URL("../../", import.meta.url));

// The pool subscribes to the dashboard socket for upload broadcasts; nothing
// here uploads.
const noSocket = {
  name: "no-socket",
  setup(build) {
    build.onResolve({ filter: /cells\/monitor$/ }, () => ({ path: "monitor", namespace: "stub" }));
    build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({ contents: "export const Monitor = { subscribe() {} };" }));
  },
};

const built = await esbuild.build({
  entryPoints: [`${root}app/javascript/src/icon_pool.js`],
  bundle:      true,
  format:      "esm",
  write:       false,
  logLevel:    "silent",
  plugins:     [noSocket],
});

const fetched = [];
globalThis.window = {};
globalThis.fetch = async (url) => {
  fetched.push(url);
  const file = { "/emoji_index.json": "public/emoji_index.json", "/icons_index.json": "public/icons_index.json", "/acnh_index.json": "public/acnh_index.json" }[url];
  const body = file ? JSON.parse(fs.readFileSync(`${root}${file}`, "utf8")) : [];
  return { ok: true, json: async () => body };
};

const { IconPool } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

const names = (rows) => rows.filter((r) => r._kind === "character").map((r) => r.n);
const cases = {};

cases.guess_only = { faces: names(await IconPool.search("raymond")), fetched_index: fetched.includes("/acnh_index.json") };
cases.best_match = (await IconPool.bestMatch("Raymond"))?._kind || null;

const raymond = (await IconPool.search("raymond", { characters: true, limit: 5 }))[0];
cases.by_name = { name: raymond.n, value: raymond.c, personality: raymond.a.personality, species: raymond.a.species };

const smugCats = names(await IconPool.search("smug cat", { characters: true, limit: 40 }));
cases.smug_cats = smugCats.slice(0, 5);
cases.named_among_descriptions = (await IconPool.search("acnh doc male bear blue", { characters: true, limit: 1 }))[0].n;
const first = async (q) => (await IconPool.search(q, { characters: true, limit: 1 }))[0];
cases.cece = (({ n, c }) => ({ n, c }))(await first("cece"));
cases.viche_unaccented = (await first("viche")).n;
cases.pave_accented = (await first("Pavé")).n;
cases.kk_punctuation = await Promise.all(["kk", "k.k", "K.K."].map(async (q) => (await first(q)).n));
cases.cookie_first =(await IconPool.search("cookie", { characters: true, limit: 1 }))[0]._kind;

process.stdout.write(JSON.stringify({ cases }));
