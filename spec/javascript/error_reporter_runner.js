// The browser error reporter (error_reporter.js): what it sends to the error
// log and what it keeps to itself. Printed as JSON for error_reporter_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

const built = await esbuild.build({
  entryPoints: [fileURLToPath(new URL("../../app/javascript/error_reporter.js", import.meta.url))],
  bundle: true,
  format: "esm",
  write: false,
  logLevel: "silent",
});

const handlers = {};
globalThis.window = {
  location: { pathname: "/lists/42", href: "https://example.com/lists/42?x=1" },
  addEventListener: (name, fn) => { handlers[name] = fn; },
};
const posts = [];
globalThis.fetch = async (url, opts) => {
  posts.push({ ...JSON.parse(opts.body), endpoint: url, keepalive: opts.keepalive });
  return { ok: true };
};

await import("data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64"));

const fire = (name, event) => handlers[name](event);
const thrown = (message, stack) => Object.assign(new TypeError(message), stack ? { stack } : {});
const out = {};

fire("error", {
  error: thrown("x is undefined", "TypeError: x is undefined\n    at render (https://example.com/assets/application.js:10:2)"),
  message: "Uncaught TypeError: x is undefined",
  filename: "https://example.com/assets/application.js",
  lineno: 10,
  colno: 2,
});
out.sent = posts[0];

// The same failure again on this page load.
fire("error", { error: thrown("x is undefined"), filename: "https://example.com/assets/application.js", lineno: 10, colno: 2 });
out.after_repeat = posts.length;

// Nothing to act on.
fire("error", { message: "Script error.", filename: "", lineno: 0, colno: 0 });
fire("error", { message: "ResizeObserver loop completed with undelivered notifications.", filename: "" });
fire("error", { error: thrown("ext broke"), filename: "chrome-extension://abcdef/content.js", lineno: 1, colno: 1 });
fire("unhandledrejection", { reason: thrown("ext promise", "TypeError: ext promise\n    at x (chrome-extension://abcdef/bg.js:1:1)") });
out.after_noise = posts.length;

// Rejections: an Error, a plain value, and one that won't serialize.
fire("unhandledrejection", { reason: thrown("fetch failed") });
fire("unhandledrejection", { reason: { status: 500 } });
const circular = {};
circular.self = circular;
fire("unhandledrejection", { reason: circular });
out.rejections = posts.slice(1).map((p) => ({ kind: p.kind, name: p.name, message: p.message }));

// A page that keeps throwing new things stops being heard after a few.
for (let i = 0; i < 30; i++) fire("error", { error: thrown(`distinct ${i}`), filename: "https://example.com/a.js" });
out.capped = posts.length;

process.stdout.write(JSON.stringify(out, null, 2));
