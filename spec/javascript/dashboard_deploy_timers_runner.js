// Loads the dashboard's Timers cell with deploys already saved from an earlier
// load, delivers deploy messages the way the deploy monitor sends them, and
// prints each deploy timer's state as JSON for dashboard_deploy_timers_spec.rb.
//
// The cell's monitor socket, sounds and text drawing are stubbed; the timers
// and how deploy messages settle them are real.
const { build } = await import("esbuild");

const stubs = {
  name: "stubs",
  setup(b) {
    b.onResolve({ filter: /(^|\/)(monitor|vars|_text)$/ }, (args) => ({ path: args.path, namespace: "stub" }));
    b.onLoad({ filter: /monitor$/, namespace: "stub" }, () => ({
      contents: `export const Monitor = { subscribe: (id, handlers) => { if (id === "deploy") globalThis.deployFeed = handlers } }`,
    }));
    b.onLoad({ filter: /_text$/, namespace: "stub" }, () => ({ contents: "export const Text = {}" }));
    b.onLoad({ filter: /vars$/, namespace: "stub" }, () => ({
      contents: `
        export const dash_colors = new Proxy({}, { get: (_t, name) => String(name) })
        export const beep = () => {}
        export const beeps = () => {}
      `,
    }));
  },
};

const bundled = await build({
  entryPoints: [new URL("../../app/javascript/src/pages/dashboard/cells/timers.js", import.meta.url).pathname],
  bundle:      true,
  format:      "esm",
  write:       false,
  logLevel:    "silent",
  plugins:     [stubs],
});

const MINUTE = 60 * 1000;
const now = Date.now();

function savedDeploy(sha, startedMinutesAgo, attrs = {}) {
  const end = now - startedMinutesAgo * MINUTE + 170 * 1000;
  return {
    kind:     "deploy",
    name:     sha,
    sha,
    start:    { seconds: 50, minutes: 2, hours: 0, days: 0 },
    total_ms: 170 * 1000,
    end_time: end,
    ...attrs,
  };
}

globalThis.localStorage = {
  store: {
    timers: JSON.stringify([
      savedDeploy("stuck", 210),
      savedDeploy("earlier", 260, { completed: true, completed_at: now - 257 * MINUTE, note: "2m40s" }),
    ]),
  },
  getItem(k) { return this.store[k] ?? null; },
  setItem(k, v) { this.store[k] = String(v); },
  removeItem(k) { delete this.store[k]; },
};

let cell;
globalThis.Cell = { register: (config) => { cell = { ...config, config: {}, flash() {}, lines() {} }; return cell; } };

await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString("base64")}`);

cell.onload.call(cell);

function deploys() {
  return Object.fromEntries(cell.data.timers.filter((t) => t.kind === "deploy").map((t) => [
    t.sha,
    { completed: t.completed, errored: t.errored, note: t.note || null, finished_at: t.completed_at ?? null },
  ]));
}

const send = (data) => globalThis.deployFeed.received.call(globalThis.deployFeed, { data });
const out = { saved_end: { stuck: now - 210 * MINUTE + 170 * 1000 } };

send({ sha: "newer", status: "deploying", start_time: new Date(now - 1 * MINUTE).toISOString() });
out.newer_running = deploys();

send({
  sha:         "newer",
  status:      "success",
  duration:    "2m45s",
  start_time:  new Date(now - 1 * MINUTE).toISOString(),
  finish_time: new Date(now).toISOString(),
});
out.newer_succeeded = deploys();

console.log(JSON.stringify(out));
