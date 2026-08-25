// Drives the real deploy_reload module and prints what it decided + whether it
// actually called reload, as JSON for deploy_reload_spec.rb.
//
// Bundled rather than imported for the same reason as monitor_fanout_runner:
// the dashboard modules use extensionless specifiers that esbuild resolves and
// node does not. The consumer is stubbed so the socket records instead of
// sending, and `location.reload` is counted instead of performed.
const esbuild = require("esbuild");
const path = require("path");

const root = path.resolve(__dirname, "../..");
const performs = [];
const reloads = [];
let store = new Map();
let storageWorks = true;

const stubConsumer = {
  name: "stub-consumer",
  setup(build) {
    build.onResolve({ filter: /channels\/consumer$/ }, () => ({
      path: "consumer-stub",
      namespace: "stub",
    }));
    build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({
      contents: `
        export default {
          connection: { reopen: () => {} },
          subscriptions: {
            create: (_params, handlers) => {
              globalThis.__connection = handlers;
              return { perform: (action, data) => globalThis.__performs.push([action, data.channel, data.sha]) };
            },
          },
        };
      `,
      loader: "js",
    }));
  },
};

globalThis.__performs = performs;
globalThis.document = { addEventListener: () => {}, visibilityState: "visible" };
globalThis.window = {
  addEventListener: () => {},
  location: { pathname: "/dashboard", search: "", reload: () => reloads.push(true) },
  sessionStorage: {
    getItem: (k) => {
      if (!storageWorks) throw new Error("storage disabled");
      return store.has(k) ? store.get(k) : null;
    },
    setItem: (k, v) => {
      if (!storageWorks) throw new Error("storage disabled");
      store.set(k, v);
    },
  },
};
// The dashboard page is present, so the module wires itself up.
globalThis.$ = (arg) => {
  if (arg === globalThis.document) return { ready: (fn) => fn() };
  return { length: 1 };
};

const say = console.log;
console.log = () => {};
console.error = () => {};

async function main() {
  const built = await esbuild.build({
    entryPoints: [path.join(root, "app/javascript/src/pages/dashboard/deploy_reload.js")],
    bundle: true,
    format: "esm",
    write: false,
    plugins: [stubConsumer],
    logLevel: "silent",
  });

  const mod = await import(
    "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
  );
  const { reloadDecision, RELOAD_STORAGE_KEY } = mod;
  const connection = globalThis.__connection;

  const out = {};

  // ---- the decision on its own ----
  out.decisions = {
    stale: reloadDecision({ target: "new", current: "old", lastReloadedFor: null }),
    no_target: reloadDecision({ target: null, current: "old", lastReloadedFor: null }),
    blank_target: reloadDecision({ target: "", current: "old", lastReloadedFor: null }),
    unknown_build: reloadDecision({ target: "new", current: undefined, lastReloadedFor: null }),
    already_current: reloadDecision({ target: "new", current: "new", lastReloadedFor: null }),
    already_reloaded: reloadDecision({ target: "new", current: "old", lastReloadedFor: "new" }),
    // A second deploy while the tab is still on the first target.
    new_target_after_reload: reloadDecision({
      target: "newer", current: "old", lastReloadedFor: "new",
    }),
  };

  // ---- the wiring, through the real socket ----
  const deliver = (reload_to) =>
    connection.received({ id: "dashboard-reload", data: { reload_to: reload_to } });

  const reset = (opts={}) => {
    reloads.length = 0;
    performs.length = 0;
    store = new Map();
    storageWorks = opts.storageWorks !== false;
    globalThis.window.DASHBOARD_SHA = opts.sha === undefined ? "old" : opts.sha;
  };

  // Asking is the whole point: a reconnect has to produce the question.
  reset();
  connection.connected();
  out.connect_asks = performs.slice();

  // The case this exists for.
  reset();
  deliver("new");
  out.stale_reloads = reloads.length;
  out.stale_remembered = store.get(RELOAD_STORAGE_KEY);

  // Same answer arriving again — a re-broadcast, a reconnect, a server that
  // never cleared the flag. The tab has already done it.
  reset();
  deliver("new");
  deliver("new");
  deliver("new");
  out.repeat_reloads = reloads.length;

  // The loop that would matter: it comes back up STILL on the old sha (rolling
  // deploy served it stale) and is told to reload to the same target again.
  reset();
  deliver("new");
  store.set(RELOAD_STORAGE_KEY, "new"); // survives the reload
  deliver("new");
  out.still_stale_after_reload_reloads = reloads.length;

  // A genuinely new deploy still gets through the guard.
  reset();
  deliver("new");
  deliver("newer");
  out.second_deploy_reloads = reloads.length;

  reset();
  deliver("old");
  out.already_current_reloads = reloads.length;

  reset({ sha: undefined });
  globalThis.window.DASHBOARD_SHA = undefined;
  deliver("new");
  out.unknown_build_reloads = reloads.length;

  reset({ storageWorks: false });
  deliver("new");
  out.no_storage_reloads = reloads.length;

  reset();
  connection.received({ id: "dashboard-reload", data: {} });
  connection.received({ id: "dashboard-reload" });
  out.empty_payload_reloads = reloads.length;

  say(JSON.stringify(out));
}

main();
