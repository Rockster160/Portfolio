// What Byte is doing in the background — the chip stack pinned top-RIGHT of the
// hero, opposite the timers.
//
// Everything here is reported by whoever is doing the work (the Mac filling in
// a line of applications, Rails reading an inbound email), so this is purely
// presentation + reconciliation, same as the timers:
//   * hydrates on load / reconnect (GET /api/v1/background_processes)
//   * applies :background MonitorChannel broadcasts
//   * repaints every 30s so a process that stops reporting starts saying so
//     rather than going on claiming progress
//   * swipe a chip away → clears it, which is the answer to one that is stuck.
//     The SERVER decides when it goes, exactly as with a timer — a chip that
//     leaves on the gesture is indistinguishable from one that leaves on a
//     failed request.
//   * a chip's links are pills under it — the job posting, the queue, the
//     email. Real anchors, so a long-press copies one and a middle-click opens
//     a tab, and the whole chip is a shortcut to the first.
//
// IT SITS OVER BUDDY, so everything that is only DECORATION is gone: no icon
// (the colour already says whether something is waiting on you) and no second
// row for the step, which is the chip's name now. What is left is the two
// things a person can act on — where the run has got to, and where to go.
//
// A cleared process is not gone: the next report under the same key puts it
// back. Clearing says "stop showing me this", not "stop doing that".

const BASE_URL = "/api/v1/background_processes";

// Mirrors BackgroundProcess::STALE_AFTER. The server sends `stale` too, but
// that is only true as of the moment it was sent — a chip sitting on screen
// has to work it out for itself or it never goes stale at all.
const STALE_AFTER_MS = 15 * 60 * 1000;

// Past this the strip is a wall rather than a glance, and Buddy is behind it.
// The ones that got cut are the ones sorted last — still running, nothing
// asked of anybody — and the line says how many.
const MAX_CHIPS = 3;

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

async function apiCall(url, method) {
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    headers: { "Accept": "application/json", "X-CSRF-Token": csrfToken() },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = await res.json().catch(() => ({}));
  // Rails wraps every response from this controller in `data`.
  return body?.data || {};
}

function isStale(p) {
  if (p.state !== "running") return false;
  if (!p.heartbeat_at) return false;
  return Date.now() - Date.parse(p.heartbeat_at) > STALE_AFTER_MS;
}

// "1/13" when both halves are known, "3" when only the count is. A total with
// no current is nothing anybody can read, so it waits for its other half.
function countText(p) {
  if (p.current == null) return "";
  return p.total == null ? String(p.current) : `${p.current}/${p.total}`;
}

export function initBuddyProcesses({ container, isBuddyActiveFn }) {
  if (!container) return null;

  const processes = new Map(); // key → serialized process
  let repaintHandle = 0;
  const clearing = new Set();
  const clearFailed = new Set();

  const isBuddyActive = () => (isBuddyActiveFn ? isBuddyActiveFn() : true);

  // ---- rendering ----------------------------------------------------------

  function ordered() {
    // Anything asking for a person first, then oldest — a long run keeps its
    // place while short ones come and go beneath it.
    return Array.from(processes.values()).sort((a, b) => {
      const wa = a.state === "running" ? 1 : 0;
      const wb = b.state === "running" ? 1 : 0;
      if (wa !== wb) return wa - wb;
      return Date.parse(a.started_at || 0) - Date.parse(b.started_at || 0);
    });
  }

  function render() {
    const all = ordered();
    const list = all.slice(0, MAX_CHIPS);
    container.hidden = all.length === 0 || !isBuddyActive();
    container.innerHTML = "";

    list.forEach((p) => {
      const stale = isStale(p);
      const chip = document.createElement("div");
      chip.className = "byte-process-chip";
      chip.dataset.processKey = p.key;
      chip.dataset.state = p.state;
      if (stale) chip.dataset.stale = "true";
      if (clearing.has(p.key)) chip.dataset.pending = "clear";
      if (clearFailed.has(p.key)) chip.dataset.pending = "clear-failed";

      // Name and count share one line; the chip itself stacks, so they need a
      // row of their own or the count lands under the name.
      const head = document.createElement("span");
      head.className = "byte-process-head";

      const name = document.createElement("span");
      name.className = "byte-process-name";
      name.textContent = p.name;
      head.appendChild(name);

      const count = countText(p);
      if (count) {
        const el = document.createElement("span");
        el.className = "byte-process-count";
        el.textContent = count;
        head.appendChild(el);
      }
      chip.appendChild(head);

      // The step it is on costs nothing here and a whole row anywhere else.
      // Stalled leads, because a frozen count reads as work still going on and
      // the chip being dimmed is the only other thing saying otherwise.
      const detail = stale ? `Stalled — ${p.detail || "no update"}` : p.detail;
      if (detail) chip.title = detail;

      // A fill along the bottom edge, with no number on it — the count above
      // is the number, and printing it twice makes the bar look like a
      // different measurement.
      if (p.total > 0 && p.current != null) {
        const bar = document.createElement("span");
        bar.className = "byte-process-bar";
        const pct = Math.max(0, Math.min(100, Math.round((p.current / p.total) * 100)));
        bar.style.setProperty("--process-progress", `${pct}%`);
        chip.appendChild(bar);
      }

      // Where it goes. Drawn, not hidden behind the chip: a tap target nobody
      // knows is a tap target is not one, and these went a whole day being
      // read as decoration on the bottom of a chip.
      const links = Array.isArray(p.links) ? p.links.filter((l) => l && l.url) : [];
      if (links.length) chip.appendChild(linkRow(links));
      // The body is a shortcut to the first one as well - a bigger target for
      // the common case, where there is only the one anyway.
      if (destination(p)) chip.dataset.hasUrl = "true";
      if (!clearing.has(p.key)) wireChip(chip, p);
      container.appendChild(chip);
    });

    // Not a chip: one dim line, so a cut is visible rather than silent. A
    // strip that showed three of eight and said nothing would read as three.
    const hidden = all.length - list.length;
    if (hidden > 0) {
      const more = document.createElement("span");
      more.className = "byte-process-more";
      more.textContent = `+${hidden} more`;
      container.appendChild(more);
    }

    ensureRepainting();
  }

  // Real anchors rather than tap handlers: a link that behaves like a link can
  // be long-pressed, copied and opened in a tab, and none of that is worth
  // reimplementing. `pointerdown` stops here so a tap on a pill never starts
  // the chip's swipe — a swipe begins on the body, which is most of the chip.
  //
  // The arrow is CSS, not text, so the label stays the label: the pills are
  // read at a glance and "Posting" was taken for a status until one of them
  // carried an arrow saying it went somewhere.
  function linkRow(links) {
    const row = document.createElement("span");
    row.className = "byte-process-links";
    links.forEach((link) => {
      const a = document.createElement("a");
      a.className = "byte-process-link";
      a.href = link.url;
      a.target = "_blank";
      a.rel = "noopener";
      a.textContent = link.label || link.url;
      a.addEventListener("pointerdown", (e) => e.stopPropagation());
      row.appendChild(a);
    });
    return row;
  }

  // The first link a process carries, which is where a tap on the body goes.
  function destination(p) {
    const links = Array.isArray(p.links) ? p.links.filter((l) => l && l.url) : [];
    return links.length ? links[0].url : null;
  }

  // Nothing here counts down, so this is only ever about a chip crossing into
  // stale. Half a minute is plenty, and it stops itself when there is nothing
  // left that could change.
  function ensureRepainting() {
    const watching = Array.from(processes.values()).some((p) => p.state === "running");
    if (watching && !repaintHandle) {
      repaintHandle = window.setInterval(render, 30000);
    } else if (!watching && repaintHandle) {
      window.clearInterval(repaintHandle);
      repaintHandle = 0;
    }
  }

  // ---- interaction: tap = open, swipe = clear -----------------------------

  function wireChip(chip, p) {
    let startX = null;
    let dragging = false;

    const release = (e) => {
      try {
        if (chip.hasPointerCapture(e.pointerId)) chip.releasePointerCapture(e.pointerId);
      } catch (_) { /* already gone */ }
    };

    // Capture, or the chip is stranded mid-swipe: without it the browser
    // retargets pointer events to whatever is under the finger now, which is
    // no longer the chip, and pointerup never arrives. Same trap the timers
    // hit (see timers.js).
    chip.addEventListener("pointerdown", (e) => {
      startX = e.clientX;
      dragging = false;
      try { chip.setPointerCapture(e.pointerId); } catch (_) { /* no capture, no drag */ }
    });
    chip.addEventListener("pointermove", (e) => {
      if (startX == null) return;
      const dx = e.clientX - startX;
      if (Math.abs(dx) > 6) dragging = true;
      if (dragging) chip.style.transform = `translateX(${dx}px)`;
      chip.style.opacity = String(Math.max(0.2, 1 - Math.abs(dx) / 160));
    });
    const finish = (e) => {
      release(e);
      if (startX == null) return;
      const dx = e.clientX - startX;
      startX = null;
      chip.style.transform = "";
      chip.style.opacity = "";
      if (dragging && Math.abs(dx) > 90) {
        clearProcess(p.key);
        return;
      }
      if (dragging) return;

      const current = processes.get(p.key) || p;
      const url = destination(current);
      if (url) window.open(url, "_blank", "noopener");
    };
    chip.addEventListener("pointerup", finish);
    chip.addEventListener("pointercancel", (e) => {
      release(e);
      startX = null;
      dragging = false;
      chip.style.transform = "";
      chip.style.opacity = "";
    });
  }

  // A swipe is a REQUEST to clear. The chip stays, visibly pending, until the
  // server agrees, and comes back with a flash if it never landed.
  async function clearProcess(key) {
    if (clearing.has(key)) return;

    clearFailed.delete(key);
    clearing.add(key);
    render();
    try {
      await apiCall(`${BASE_URL}/${encodeURIComponent(key)}`, "DELETE");
      clearing.delete(key);
      processes.delete(key);
      render();
    } catch (e) {
      console.warn("[buddy] background clear failed", e);
      clearing.delete(key);
      clearFailed.add(key);
      render();
      window.setTimeout(() => {
        if (!clearFailed.delete(key)) return;

        render();
      }, 2000);
    }
  }

  // ---- store mutations ----------------------------------------------------

  function upsert(p) {
    if (!p || !p.key) return;
    if (p.state === "finished" || p.finished_at) processes.delete(p.key);
    else processes.set(p.key, p);
    render();
  }

  // ---- public surface -----------------------------------------------------

  return {
    async hydrate() {
      try {
        const data = await apiCall(BASE_URL, "GET");
        processes.clear();
        (data.processes || []).forEach((p) => processes.set(p.key, p));
        render();
      } catch (e) {
        console.warn("[buddy] background hydrate failed", e);
      }
    },

    applyBroadcast(payload) {
      const data = payload?.data || {};
      const p = data.process;
      if (!p) return;
      if (data.reason === "cleared") {
        // However it was cleared, the swipe that asked for it is answered.
        clearing.delete(p.key);
        clearFailed.delete(p.key);
        processes.delete(p.key);
        render();
        return;
      }
      upsert(p);
    },

    setActive() {
      render();
    },
  };
}
