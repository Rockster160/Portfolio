// The strip of conditions still standing open (Buddy::Alerts), along the bottom
// of the hero.
//
// An alert owns ONE bubble for as long as it is open, which is what stops a
// standing condition turning into a run of identical notifications — and is
// also its one weakness: a thread moves on, and a bubble raised on Tuesday is a
// hundred messages up by Thursday. The strip is the answer to that. It is drawn
// from the database on every load, so an outstanding thing cannot be lost by
// being scrolled past.
//
// Under the pet rather than above the composer: a bar across the foot of the
// page reads as an app-level banner, and this is Buddy's own area, holding what
// Buddy is carrying. It OVERLAYS that area — absolutely positioned, the same
// way the timer chips are — because in flow it took its height off the
// character, and a bad night would shrink him.
//
// At most two rows are ever built, and the rest become a count. A scrolling
// strip was the first attempt and was worse than the problem: a native
// scrollbar down the side of the pet, over a list of two-line rows nobody
// wanted to scroll.
//
// Two things a row does:
//
//   * tapping it goes to the bubble the words came from, which may be in
//     another thread and days back
//   * the ✕ LETS GO of it, which is not the same as resolving it. Nobody
//     checked the condition; the person said stop asking. That matters for a
//     reason with nothing to do with tidiness: while an alert stands open it
//     owns its key, so every later occurrence lands on that same buried bubble
//     instead of announcing itself. Letting go frees the key, and the next
//     occurrence opens fresh and buzzes like the first one did.
async function post(url) {
  const csrf =
    document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
  const res = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-CSRF-Token": csrf },
  });
  if (!res.ok) throw new Error(`http_${res.status}`);
  return res.json();
}

// What one row says. The body is the caller's own sentence, so it is the label;
// the count rides along only when there IS one to report, for the same reason
// the bubble's own status line stays empty on a condition seen once.
// How many rows are ever drawn. The rest are a count — see the note up top on
// why this doesn't scroll.
export const MAX_ROWS = 2;

// The line standing in for everything past MAX_ROWS, or null when they all fit.
export function overflowLabel(total, max = MAX_ROWS) {
  const hidden = Number(total || 0) - max;
  return hidden > 0 ? `+${hidden} more outstanding` : null;
}

export function alertRowLabel(alert) {
  const body = (alert?.body || "").toString().trim();
  const count = Number(alert?.count || 0);
  return count > 1 ? `${body} (×${count})` : body;
}

export function initAlertStrip({ root, onJump }) {
  // The kiosk has no strip and cannot be switched away from, so there is
  // nowhere to put one and nothing a tap could do. Every method still answers,
  // because the caller shouldn't have to know which surface it is on.
  if (!root) return { setAlerts: () => {}, render: () => {}, alerts: () => [] };

  let alerts = [];

  function render() {
    root.textContent = "";
    root.hidden = alerts.length === 0;
    if (!alerts.length) return;

    alerts.slice(0, MAX_ROWS).forEach((alert) => {
      const row = document.createElement("div");
      row.className = "byte-alert-row";
      row.dataset.alertId = String(alert.id);

      const go = document.createElement("button");
      go.type = "button";
      go.className = "byte-alert-row-label";
      go.textContent = alertRowLabel(alert);
      // The words are the caller's and can be long; the full sentence is the
      // tooltip so a truncated row is never the only version of it.
      go.title = alert.body || "";
      go.addEventListener("click", () => onJump?.(alert));

      const drop = document.createElement("button");
      drop.type = "button";
      drop.className = "byte-alert-row-drop";
      drop.setAttribute("aria-label", "Let go of this");
      drop.title = "Let go of this - it stops asking, and says so";
      drop.textContent = "✕";
      drop.addEventListener("click", async () => {
        drop.disabled = true;
        try {
          const body = await post(`/buddy/alerts/${alert.id}/dismiss`);
          // The server answers with the whole list, so a dismissal from another
          // device that landed in between is picked up here rather than being
          // painted over with this page's stale idea of what is open.
          setAlerts(body?.alerts);
        } catch (e) {
          drop.disabled = false;
          console.warn("[byte] alert dismiss failed", e);
        }
      });

      row.append(go, drop);
      root.appendChild(row);
    });

    // Not tappable, and deliberately: there is nothing useful for a tap to do
    // that clearing the two above it doesn't already do — each one dropped
    // promotes the next into view.
    const more = overflowLabel(alerts.length);
    if (more) {
      const note = document.createElement("div");
      note.className = "byte-alert-more";
      note.textContent = more;
      root.appendChild(note);
    }
  }

  function setAlerts(next) {
    alerts = Array.isArray(next) ? next : [];
    render();
  }

  return { setAlerts, render, alerts: () => alerts };
}
