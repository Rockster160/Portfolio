// A standing alert on the board, in the pet's own chat bubble. The same
// Buddy::Alerts the chat surfaces in the strip (the laundry gate is open, the
// Whisper is hungry) show HERE as a bubble that holds while the condition
// stands, and the pet does its alarm shuffle beside it — the back-and-forth a
// ringing timer does, but SILENT, because a standing condition is noticed, not
// silenced.
//
// Fed the same alert list the strip gets (bootstrap + the :alerts broadcast +
// the /buddy/alerts refresh). Board only: with no bubble element this is a
// no-op, so the caller can wire it on every surface and let it fall away off
// the board.

import { startAlertFlip, stopAlertFlip } from "./alarm";
import { alertRowText } from "../alert_strip";
import { groupsOverlap } from "./board_scope";

const CYCLE_MS = 5000;

export function initBoardAlert({ bubble, hero, tags }) {
  if (!bubble) return { setAlerts: () => {}, setTags: () => {} };

  // Mutable: the board can be repointed at other groups live, and setTags
  // re-filters the alerts already in hand against the new set.
  let watched = Array.isArray(tags) ? tags : [];
  let lastAlerts = [];
  let alerts = [];
  let cycleTimer = 0;
  let index = 0;

  function stopCycle() {
    if (cycleTimer) {
      clearInterval(cycleTimer);
      cycleTimer = 0;
    }
  }

  function paint() {
    const alert = alerts[index % alerts.length];
    bubble.textContent = alertRowText(alert?.body);
  }

  function setAlerts(next) {
    if (Array.isArray(next)) lastAlerts = next;
    // Only the alerts aimed at a group this board watches. An alert with no
    // groups belongs to no board — it still stands in the chat strip, just not
    // out here — so an unrelated condition never lights up the Whisper wall.
    alerts = lastAlerts.filter((a) => a && a.body && groupsOverlap(a.groups, watched));

    if (alerts.length === 0) {
      stopCycle();
      bubble.hidden = true;
      bubble.textContent = "";
      stopAlertFlip({ hero });
      return;
    }

    index = 0;
    paint();
    bubble.hidden = false;
    startAlertFlip({ hero });

    // More than one standing at once: rotate through them so none is hidden
    // behind the first. One alert holds steady.
    stopCycle();
    if (alerts.length > 1) {
      cycleTimer = window.setInterval(() => {
        index = (index + 1) % alerts.length;
        paint();
      }, CYCLE_MS);
    }
  }

  // Repointed at other groups: re-filter the alerts already in hand so a
  // newly-watched condition shows (and a no-longer-watched one clears) at once.
  function setTags(next) {
    watched = Array.isArray(next) ? next.map((t) => String(t).toLowerCase()) : [];
    setAlerts(lastAlerts);
  }

  return { setAlerts, setTags };
}
