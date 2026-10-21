// A Jil select whose options end in `*` takes any typed value as well as its
// choices: the option list it parses, and where a loaded value lands. Printed
// as JSON for jil_free_text_select_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

// Sortable touches the DOM when it loads; nothing here sorts.
const stubs = {
  name: "stubs",
  setup(build) {
    build.onResolve({ filter: /Sortable\.min\.js$/ }, () => ({ path: "sortable", namespace: "stub" }));
    build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({ contents: "export default class {}", loader: "js" }));
  },
};

const built = await esbuild.build({
  stdin: {
    contents: `
      export { default as Arg } from "./arg.js";
      export { setSelectValue, OTHER } from "./form_helpers.js";
    `,
    resolveDir: fileURLToPath(new URL("../../app/javascript/jil/", import.meta.url)),
  },
  bundle: true,
  format: "esm",
  write: false,
  plugins: [stubs],
  logLevel: "silent",
});

globalThis.window = globalThis;
globalThis.document = { addEventListener() {}, querySelector: () => null, querySelectorAll: () => [] };

const { Arg, setSelectValue, OTHER } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

const out = {};
const free = new Arg(null, '["sleeping" "thinking" "wave" *]');
const fixed = new Arg(null, '["seconds" "minutes"]');
out.free = { options: free.options, freeText: free.freeText };
out.fixed = { options: fixed.options, freeText: fixed.freeText };

// The select and its "<other>" box, as the editor builds them.
function wrapper(withOther) {
  const classes = new Set(["select-other", "hidden"]);
  const other = { value: "", classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) }, hidden: () => classes.has("hidden") };
  const select = {
    value: "",
    options: ["sleeping", "thinking", "wave", OTHER, "<dynamic>"].map((value) => ({ value })),
    parentElement: { querySelector: () => (withOther ? other : null) },
  };
  return { select, other };
}

const known = wrapper(true);
setSelectValue(known.select, "thinking");
out.known = { select: known.select.value, otherHidden: known.other.hidden() };

const typed = wrapper(true);
setSelectValue(typed.select, "nerd");
out.typed = { select: typed.select.value, other: typed.other.value, otherHidden: typed.other.hidden() };

process.stdout.write(JSON.stringify(out));
