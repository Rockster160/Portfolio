// A wall screen (kiosk or board) taking an update. It has no header to show the
// "!" on and nobody may ever press it, so it reloads itself - but never out from
// under someone using it. A short countdown runs along the top instead, and
// anything a person does restarts it, as does anything left open over the
// screen (`held`). Pause stops it for good - through later deploys and the
// reloads of this tab, until someone resumes it - and the reload button goes
// now.

export const COUNTDOWN_S = 10;
// How long the screen waits on a reload before trying it again. A navigation
// that can't land doesn't fail - the page just stays - so this is the only
// thing that notices.
export const STALL_MS = 15000;
const PAUSED_KEY = "byte.reloadPaused";

function readPaused() {
  try {
    return window.sessionStorage.getItem(PAUSED_KEY) === "true";
  } catch (_) {
    return false;
  }
}

function writePaused(on) {
  try {
    if (on) window.sessionStorage.setItem(PAUSED_KEY, "true");
    else window.sessionStorage.removeItem(PAUSED_KEY);
  } catch (_) {}
}

// Anything a person does with their hands. `scroll` and `focus` are listened
// for with capture because neither bubbles from where it starts.
const ACTIVITY = [
  "pointerdown",
  "pointermove",
  "touchstart",
  "keydown",
  "wheel",
  "scroll",
  "input",
  "focus",
];

// Every version this tab has run or already reloaded for, newest last. A wall
// screen only takes an update to one it has never had: during a deploy the old
// and new servers can answer alternately, and a page already on the new build
// heard the old one's shell as yet another update and reloaded again.
const SEEN_KEY = "byte.versionsSeen";

function readSeen() {
  try {
    const list = JSON.parse(window.sessionStorage.getItem(SEEN_KEY) || "[]");
    return Array.isArray(list) ? list : [];
  } catch (_) {
    return [];
  }
}

function writeSeen(list) {
  try {
    window.sessionStorage.setItem(SEEN_KEY, JSON.stringify(list.slice(-20)));
  } catch (_) {}
}

// Whether `version` is an update this tab should take, given the one it's
// running (`mine`). Remembers both, so each is answered once.
export function updateWanted(version, mine) {
  const seen = readSeen();
  if (mine && !seen.includes(mine)) seen.push(mine);
  const wanted = !!version && version !== mine && !seen.includes(version);
  if (wanted) seen.push(version);
  writeSeen(seen);
  return wanted;
}

export function initReloadCountdown({ el, reload, held }) {
  if (!el) return { start: reload };

  const countEl = el.querySelector("[data-reload-count]");
  const pauseEl = el.querySelector("[data-reload-pause]");
  const nowEl = el.querySelector("[data-reload-now]");
  let remaining = COUNTDOWN_S;
  let timer = null;
  let started = false;
  let paused = readPaused();
  // Past zero: the reload is under way, which can take a few seconds (the new
  // worker, emptying the caches) or stall on a bad connection. Said as such,
  // with the arrow turning, rather than sitting on "1".
  let reloading = false;
  let stallTimer = null;

  function paint() {
    el.dataset.paused = String(paused);
    el.dataset.reloading = String(reloading);
    if (countEl) countEl.textContent = reloading ? "Updating…" : String(remaining);
    if (pauseEl) {
      const label = paused ? "Resume the update countdown" : "Pause the update";
      pauseEl.title = label;
      pauseEl.setAttribute("aria-label", label);
    }
  }

  function restart() {
    if (!started || paused || reloading) return;
    remaining = COUNTDOWN_S;
    paint();
  }

  function go() {
    clearInterval(timer);
    timer = null;
    clearTimeout(stallTimer);
    reloading = true;
    remaining = 0;
    paint();
    Promise.resolve().then(reload).catch(() => {});
    // Still here: try again, or wait while there's no network to land on.
    stallTimer = setTimeout(function retry() {
      if (navigator.onLine === false) {
        stallTimer = setTimeout(retry, STALL_MS);
        return;
      }
      go();
    }, STALL_MS);
  }

  function tick() {
    if (paused) return;
    // Something open over the screen, or no network to fetch the new page
    // over: it waits, rather than counting down on someone mid-task or
    // emptying the caches for a navigation that can't land.
    if (held?.() || navigator.onLine === false) return restart();

    remaining -= 1;
    if (remaining <= 0) return go();
    paint();
  }

  ACTIVITY.forEach((type) =>
    window.addEventListener(type, restart, { capture: true, passive: true }),
  );

  pauseEl?.addEventListener("click", () => {
    if (reloading) return;
    paused = !paused;
    writePaused(paused);
    if (!paused) remaining = COUNTDOWN_S;
    paint();
  });
  // Reloading by hand is someone choosing the update, so a pause is over.
  nowEl?.addEventListener("click", () => {
    writePaused(false);
    go();
  });

  return {
    // An update is waiting. Once: a second notice while it's already counting
    // changes nothing, and a paused one stays paused.
    start() {
      if (started) return;
      started = true;
      el.hidden = false;
      paint();
      timer = setInterval(tick, 1000);
    },
  };
}
