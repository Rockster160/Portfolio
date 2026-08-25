// Drives the real Monitor bus and prints what it sent + who it reached, as
// JSON for monitor_fanout_spec.rb.
//
// The module is bundled rather than imported: it reaches for
// `./../../../channels/consumer` with no extension, which esbuild resolves and
// node does not. Bundling also gives us the seam we need — the consumer is
// replaced with a fake whose `subscriptions.create` hands back a socket that
// records `perform` calls instead of making them, and keeps the connection
// handlers so a disconnect/reconnect can be replayed.
const esbuild = require("esbuild");
const path = require("path");

const root = path.resolve(__dirname, "../..");
const performs = [];
let connection = {};

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
          connection: { reopen: () => globalThis.__reopens.push(true) },
          subscriptions: {
            create: (_params, handlers) => {
              globalThis.__connection = handlers;
              return { perform: (action, data) => globalThis.__performs.push([action, data.channel]) };
            },
          },
        };
      `,
      loader: "js",
    }));
  },
};

globalThis.__performs = performs;
globalThis.__reopens = [];
globalThis.window = { location: { pathname: "/dashboard", search: "" }, addEventListener: () => {} };
globalThis.document = { addEventListener: () => {}, visibilityState: "visible" };

// The module narrates its own connects, and the two deliberate throws below are
// reported by design. stdout has to be the JSON and nothing else.
const say = console.log;
console.log = () => {};
console.error = () => {};

async function main() {
  const built = await esbuild.build({
    entryPoints: [path.join(root, "app/javascript/src/pages/dashboard/cells/monitor.js")],
    bundle: true,
    format: "esm",
    write: false,
    plugins: [stubConsumer],
    logLevel: "silent",
  });

  const { Monitor } = await import(
    "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
  );
  connection = globalThis.__connection;

  const out = {};
  const flush = () => new Promise((r) => setTimeout(r, 0));

  // Two subscribers, one channel. Both ask; the server is asked once.
  const reset = () => { performs.length = 0; };

  const a = Monitor.subscribe("chores", {});
  const b = Monitor.subscribe("chores", {});
  const c = Monitor.subscribe("timers", {});

  reset();
  a.resync();
  b.resync();
  out.same_channel_one_turn = performs.slice();

  await flush();
  reset();
  a.resync();
  b.resync();
  c.resync();
  out.two_channels_one_turn = performs.slice();

  // A later turn is a real second question, not a duplicate.
  await flush();
  reset();
  a.resync();
  await flush();
  a.resync();
  out.same_channel_later_turn = performs.slice();

  // Different actions on one channel are different questions.
  await flush();
  reset();
  a.resync();
  a.refresh();
  a.execute();
  out.distinct_actions_one_turn = performs.slice();

  // The reconnect sweep: every subscriber's `connected` runs, one perform.
  await flush();
  reset();
  const reached = [];
  const d = Monitor.subscribe("agenda", {
    connected: function () { reached.push("d"); this.resync(); },
  });
  const e = Monitor.subscribe("agenda", {
    connected: function () { reached.push("e"); this.resync(); },
  });
  reset();
  reached.length = 0;
  connection.connected();
  out.reconnect_performs = performs.filter((p) => p[1] === "agenda");
  out.reconnect_reached = reached.slice();

  // One broken subscriber must not starve the rest of its channel.
  await flush();
  const got = [];
  Monitor.subscribe("weather", {
    received: () => { got.push("first"); throw new Error("boom"); },
  });
  Monitor.subscribe("weather", { received: () => got.push("second") });
  connection.received({ id: "weather" });
  out.received_after_throw = got.slice();

  // ...nor take down the reconnect sweep for every other channel on the page.
  await flush();
  const swept = [];
  Monitor.subscribe("printer", {
    connected: () => { swept.push("printer"); throw new Error("boom"); },
  });
  Monitor.subscribe("uptime", { connected: () => swept.push("uptime") });
  swept.length = 0;
  connection.connected();
  out.sweep_after_throw = swept.slice();

  say(JSON.stringify(out));
}

main();
