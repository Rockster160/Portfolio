// Drives the real wall-screen reload countdown with a hand-cranked clock and
// prints what happened, as JSON for reload_countdown_spec.rb.
const listeners = {};
let online = true;
let tickFn = null;

const session = {};
globalThis.window = {
  addEventListener: (type, fn) => {
    (listeners[type] ||= []).push(fn);
  },
  sessionStorage: {
    getItem: (k) => session[k] ?? null,
    setItem: (k, v) => {
      session[k] = String(v);
    },
    removeItem: (k) => {
      delete session[k];
    },
  },
};
globalThis.navigator = {
  get onLine() {
    return online;
  },
};
globalThis.setInterval = (fn) => {
  tickFn = fn;
  return 1;
};
globalThis.clearInterval = () => {
  tickFn = null;
};

function fakeEl() {
  const handlers = {};
  return {
    hidden: true,
    dataset: {},
    textContent: "",
    title: "",
    setAttribute() {},
    addEventListener: (type, fn) => {
      handlers[type] = fn;
    },
    click: () => handlers.click?.(),
  };
}
const parts = {
  "[data-reload-count]": fakeEl(),
  "[data-reload-pause]": fakeEl(),
  "[data-reload-now]": fakeEl(),
};
const el = { ...fakeEl(), querySelector: (sel) => parts[sel] };

const { initReloadCountdown, COUNTDOWN_S } = await import(
  "../../app/javascript/src/pages/byte/reload_countdown.js"
);

let reloads = 0;
let held = false;
const countdown = initReloadCountdown({ el, reload: () => reloads++, held: () => held });
const tick = (n) => {
  for (let i = 0; i < n; i++) tickFn?.();
};
const touch = () => listeners.pointerdown.forEach((fn) => fn());
const count = () => parts["[data-reload-count]"].textContent;

const out = { countdown_s: COUNTDOWN_S };

out.hidden_before_start = el.hidden;
countdown.start();
out.shown_on_start = !el.hidden;
out.first_text = count();

tick(4);
out.after_four = count();
touch();
out.after_touch = count();

held = true;
tick(20);
out.held_reloads = reloads;
out.held_text = count();
held = false;

online = false;
tick(20);
out.offline_reloads = reloads;
online = true;

parts["[data-reload-pause]"].click();
tick(60);
out.paused_reloads = reloads;
out.paused_text = count();
out.paused_flag = el.dataset.paused;

// The next deploy reloads nothing while paused: a fresh page in this tab, told
// of another update, opens on the pause.
const laterParts = {
  "[data-reload-count]": fakeEl(),
  "[data-reload-pause]": fakeEl(),
  "[data-reload-now]": fakeEl(),
};
const later = { ...fakeEl(), querySelector: (sel) => laterParts[sel] };
let laterReloads = 0;
const firstTick = tickFn;
initReloadCountdown({ el: later, reload: () => laterReloads++, held: () => false }).start();
tick(60);
tickFn = firstTick;
out.next_deploy_paused = later.dataset.paused;
out.next_deploy_reloads = laterReloads;

parts["[data-reload-pause]"].click();
tick(COUNTDOWN_S - 1);
out.one_short_reloads = reloads;
tick(1);
out.at_zero_reloads = reloads;

console.log(JSON.stringify(out));
