// Loads the dashboard's Month cell on 23 Nov 2026 with the "every 4 weeks, warn
// 1 week before" marker, answers the last-occurrence lookup with each scenario's
// date, and prints the dotted days of the drawn grid as JSON for
// dashboard_month_markers_spec.rb.
//
// The clock, the server and the text drawing are stubbed; the grid and the
// marker placement are real.
const { build } = await import("esbuild");

const stubs = {
  name: "stubs",
  setup(b) {
    b.onResolve({ filter: /(^|\/)(_time|vars|_text)$/ }, (args) => ({ path: args.path, namespace: "stub" }));
    b.onLoad({ filter: /_time$/, namespace: "stub" }, () => ({
      contents: `
        export const Time = {
          now: () => new Date(2026, 10, 23, 12, 0, 0),
          msUntilNextDay: () => 0,
          seconds: (n) => n * 1000,
        }
      `,
    }));
    b.onLoad({ filter: /_text$/, namespace: "stub" }, () => ({
      contents: `
        export const Text = {
          center: (text) => text,
          color: (color, text) => "<" + color + ">" + text,
          bgColor: (_color, text) => text,
        }
      `,
    }));
    b.onLoad({ filter: /vars$/, namespace: "stub" }, () => ({
      contents: "export const dash_colors = new Proxy({}, { get: (_t, name) => String(name) })",
    }));
  },
};

const bundled = await build({
  entryPoints: [new URL("../../app/javascript/src/pages/dashboard/demo/month.js", import.meta.url).pathname],
  bundle:      true,
  format:      "esm",
  write:       false,
  logLevel:    "silent",
  plugins:     [stubs],
});

let registered;
let lastOccurrence;
globalThis.Cell = { register: (init) => { registered = init } };
globalThis.Server = {
  get: (_path, params) => ({
    then: (done) => {
      done(Object.fromEntries(params.queries.map((query) => [query, lastOccurrence])));
      return { then: (next) => next() };
    },
  }),
};
globalThis.$ = {};

await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString("base64")}`);

// Each dotted day as "<month day>": "<dot color>", where the month is the grey
// of a trailing day from next month or the white of this one.
function dotsAfter(lastIso) {
  lastOccurrence = lastIso;
  const cell = {
    config: { markers: [{ query: "name::P", period: "4w", warn: "1w", color: "red", warn_color: "orange" }] },
    lines(drawn) { this.drawn = drawn },
  };
  registered.reloader.call(cell);

  const dots = {};
  cell.drawn.slice(3).join(" ").replace(/<(\w+)>•<(\w+)>\s*(\d+)/g, (_match, dot, day, date) => {
    dots[(day === "grey" ? "next " : "this ") + date] = dot;
  });
  return dots;
}

console.log(JSON.stringify({
  due_past_the_grid: dotsAfter("2026-11-11T18:18:35"),
  due_on_the_grid:   dotsAfter("2026-10-28T09:00:00"),
  warn_past_the_grid: dotsAfter("2026-11-20T09:00:00"),
}));
