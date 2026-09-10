// The pinned strip of conditions still standing open (Buddy::Alerts).
//
// An alert owns ONE bubble for as long as it is open, which is what stops a
// standing condition turning into a run of identical notifications — and is
// also its one weakness: a thread moves on, and a bubble raised on Tuesday is a
// hundred messages up by Thursday. The strip is the answer to that. It is drawn
// from the database on every load and pinned above the composer, so an
// outstanding thing cannot be lost by being scrolled past.
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

    alerts.forEach((alert) => {
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
  }

  function setAlerts(next) {
    alerts = Array.isArray(next) ? next : [];
    render();
  }

  return { setAlerts, render, alerts: () => alerts };
}
