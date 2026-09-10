// Drives the real idle-reload module and prints what it decided, as JSON for
// byte_idle_reload_spec.rb. The clock, the page state and the reload itself are
// all stubbed, so this asks the rule directly rather than inferring it from
// whether a navigation happened.
const listeners = {};
let hidden = false;
let focused = true;
let online = true;

globalThis.window = {
  addEventListener: (type, fn) => {
    (listeners[type] ||= []).push(fn);
  },
};
globalThis.document = {
  get hidden() {
    return hidden;
  },
  hasFocus: () => focused,
  addEventListener: (type, fn) => {
    (listeners[type] ||= []).push(fn);
  },
};
globalThis.navigator = {
  get onLine() {
    return online;
  },
};

const { idleReloadDecision, initIdleReload, IDLE_MS } = await import(
  "../../app/javascript/src/pages/byte/idle_reload.js"
);

const base = {
  idleFor: IDLE_MS + 1,
  hidden: true,
  focused: false,
  online: true,
  quiet: true,
};
const decide = (over = {}) => idleReloadDecision({ ...base, ...over });

const out = {};

// ---- the rule on its own --------------------------------------------------
out.idle_ms = IDLE_MS;
out.decisions = {
  unattended: decide(),
  // Sitting still with the app in front of them is READING, not idling.
  reading: decide({ hidden: false, focused: true }),
  // Another window on top of it counts, even on a visible page.
  window_behind: decide({ hidden: false, focused: false }),
  just_touched: decide({ idleFor: 60 * 1000 }),
  at_the_boundary: decide({ idleFor: IDLE_MS }),
  a_hair_short: decide({ idleFor: IDLE_MS - 1 }),
  offline: decide({ online: false }),
  not_quiet: decide({ quiet: false }),
  // Order matters: still being used beats every other reason to decline.
  used_and_offline: decide({ idleFor: 1000, online: false }),
};

// ---- the wiring -----------------------------------------------------------
let clock = 1_000_000;
let quiet = true;
const reloads = [];
const idle = initIdleReload({
  quiet: () => quiet,
  reload: () => reloads.push(clock),
  now: () => clock,
});

out.armed_at_rest = idle.armed();
idle.arm();
out.armed_after_arm = idle.armed();

// Freshly armed, nothing has aged yet.
hidden = true;
focused = false;
idle.tick();
out.reloads_while_fresh = reloads.length;

// Long enough, unattended, and settled.
clock += IDLE_MS + 1;
idle.tick();
out.reloads_when_unattended = reloads.length;
out.armed_after_reload = idle.armed();

// It disarms itself, so the timer firing again behind an in-flight navigation
// cannot nuke the caches a second time.
idle.tick();
out.reloads_after_a_second_tick = reloads.length;

// ---- a touch puts the clock back ------------------------------------------
clock = 2_000_000;
reloads.length = 0;
const idle2 = initIdleReload({
  quiet: () => quiet,
  reload: () => reloads.push(clock),
  now: () => clock,
});
idle2.arm();
clock += IDLE_MS + 1;
// Whatever they did with their hands, the module heard it through window.
listeners.pointermove.forEach((fn) => fn());
idle2.tick();
out.reloads_after_a_touch = reloads.length;
out.decision_after_a_touch = idle2.decide();

clock += IDLE_MS + 1;
idle2.tick();
out.reloads_once_the_touch_ages_out = reloads.length;

// ---- coming back to the app is using it -----------------------------------
clock = 3_000_000;
reloads.length = 0;
const idle3 = initIdleReload({
  quiet: () => quiet,
  reload: () => reloads.push(clock),
  now: () => clock,
});
idle3.arm();
clock += IDLE_MS + 1;
hidden = false;
listeners.visibilitychange.forEach((fn) => fn());
hidden = true;
idle3.tick();
out.reloads_after_returning = reloads.length;

// ---- something open over the thread ---------------------------------------
clock = 4_000_000;
reloads.length = 0;
quiet = false;
const idle4 = initIdleReload({
  quiet: () => quiet,
  reload: () => reloads.push(clock),
  now: () => clock,
});
idle4.arm();
clock += IDLE_MS + 1;
idle4.tick();
out.reloads_while_unsettled = reloads.length;
out.decision_while_unsettled = idle4.decide();

// Every armed interval holds node open, and this file has to exit.
[idle, idle2, idle3, idle4].forEach((i) => i.disarm());

process.stdout.write(JSON.stringify(out, null, 2));
