// A wall screen (kiosk or board) taking an update. It has no header to show the
// "!" on and nobody may ever press it, so it reloads itself - but never out from
// under someone using it. A short countdown runs along the top instead, and
// anything a person does restarts it, as does anything left open over the
// screen (`held`). Pause stops it for good - through later deploys and the
// reloads of this tab, until someone resumes it - and the reload button goes
// now.

export const COUNTDOWN_S = 10;
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

export function initReloadCountdown({ el, reload, held }) {
  if (!el) return { start: reload };

  const countEl = el.querySelector("[data-reload-count]");
  const pauseEl = el.querySelector("[data-reload-pause]");
  const nowEl = el.querySelector("[data-reload-now]");
  let remaining = COUNTDOWN_S;
  let timer = null;
  let started = false;
  let paused = readPaused();

  function paint() {
    el.dataset.paused = String(paused);
    if (countEl) countEl.textContent = String(remaining);
    if (pauseEl) {
      const label = paused ? "Resume the update countdown" : "Pause the update";
      pauseEl.title = label;
      pauseEl.setAttribute("aria-label", label);
    }
  }

  function restart() {
    if (!started || paused) return;
    remaining = COUNTDOWN_S;
    paint();
  }

  function go() {
    clearInterval(timer);
    timer = null;
    reload();
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
