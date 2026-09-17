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
//   * an × on the chip clears it, which is the answer to one that is stuck.
//     The SERVER decides when it goes — a chip that leaves on the tap is
//     indistinguishable from one that leaves on a failed request.
//
//     It was a SWIPE until 17 Sep and never worked. The gesture depends on
//     pointer capture, and when the capture doesn't take, the browser retargets
//     to whatever is under the finger now - so `pointerup` never reaches the
//     chip, the drag is never finished, and the chip sits where it was dragged,
//     often right off the edge of the strip. It LOOKS dismissed, nothing was
//     ever sent, and it is still there on the next device to look. Rocco:
//     "the swipe away feature has just been bad from the start".
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

import { onChipTap } from "./chip_taps";

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
      // On the chip rather than in the head row: it is positioned against the
      // chip's right edge and spans its full height, so it belongs to the chip.
      if (!clearing.has(p.key)) chip.appendChild(closeButton(p));

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
      wireChip(chip, p);
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
  // reimplementing.
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

  // ---- interaction: tap = open, × = clear ---------------------------------

  // A real button, so it is reachable by keyboard and reads as a control to a
  // screen reader. `type` matters nowhere here and costs nothing to be right.
  // The hit area is the chip's whole right edge — see .byte-chip-close.
  function closeButton(p) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "byte-chip-close";
    btn.textContent = "×";
    btn.title = `Dismiss ${p.name}`;
    btn.setAttribute("aria-label", `Dismiss ${p.name}`);
    onChipTap(btn, (e) => {
      e.stopPropagation();
      e.preventDefault();
      clearProcess(p.key);
    });
    return btn;
  }

  // The body is a shortcut to the first link. The × and the link pills are
  // inside it, so a tap that landed on one of those is theirs — and `onChipTap`
  // is what keeps a drag, or a click left over from a gesture that started on
  // a chip that has since been re-rendered, from counting as one.
  function wireChip(chip, p) {
    onChipTap(chip, (e) => {
      if (e.target?.closest?.("a, button")) return;

      const current = processes.get(p.key) || p;
      const url = destination(current);
      if (url) window.open(url, "_blank", "noopener");
    });
  }

  // A tap on the × is a REQUEST to clear. The chip stays, visibly pending,
  // until the server agrees, and comes back with a flash if it never landed.
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
        // However it was cleared, the tap that asked for it is answered.
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
