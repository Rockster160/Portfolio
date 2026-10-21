// A standing alert on the board, in the pet's own chat bubble. The same
// Buddy::Alerts the chat surfaces in the strip (the laundry gate is open, the
// Whisper is hungry) show HERE as a bubble that holds while the condition
// stands. Beside it the pet does its alarm shuffle — the back-and-forth a
// ringing timer does, but SILENT, because a standing condition is noticed, not
// silenced — UNLESS the alert names a face of its own, in which case the pet
// HOLDS that face (the laundry gate's "up to no good" look) through the hero's
// held-state layer, so it reads as a mood that stays until the gate shuts.
//
// Fed the same alert list the strip gets (bootstrap + the :alerts broadcast +
// the /buddy/alerts refresh). Board only: with no bubble element this is a
// no-op, so the caller can wire it on every surface and let it fall away off
// the board.
//
// The newest high-priority item of the board's list (Buddy::BoardList) is said
// here too, first, until it's checked off. It's a thing to do rather than a
// condition, so the pet says it without the shuffle, and while any high item is
// open the pet holds a surprised face.

import { startAlertFlip, stopAlertFlip } from "./alarm";
import { FACE_STRENGTH, strengthOr } from "./face_strength.js";
import { alertRowText } from "../alert_strip";
import { groupsOverlap, newestListItem } from "./board_scope";

const CYCLE_MS = 5000;

// The hold key the board alert owns on the hero (see hero.holdExpression). One
// key, re-pointed as the showing alert changes, released when none stands.
const ALERT_HOLD = "board-alert";
const HIGH_HOLD = "board-list-high";
const HIGH_FACE = "surprised";

export function initBoardAlert({ bubble, hero, tags }) {
  if (!bubble) return { setAlerts: () => {}, setTags: () => {}, setItems: () => {} };

  // Mutable: the board can be repointed at other groups live, and setTags
  // re-filters the alerts already in hand against the new set.
  let watched = Array.isArray(tags) ? tags : [];
  let lastAlerts = [];
  let listAlert = null;
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
    // A standing condition that carries an icon (a hungry dog's 🍖) shows the
    // glyph big, read from across the room — the words ride along as the title
    // for anyone up close. Everything else is the sentence, as before.
    const icon = alert?.icon;
    if (icon) {
      bubble.textContent = icon;
      bubble.dataset.icon = "true";
      bubble.title = alertRowText(alert?.body);
    } else {
      bubble.textContent = alertRowText(alert?.body);
      delete bubble.dataset.icon;
      bubble.removeAttribute("title");
    }

    // The pet's face follows whichever alert is showing. One that NAMES a face
    // (the laundry gate's "up to no good" look) HOLDS it steady through the
    // hero's state layer, so it survives a mood broadcast or the idle reset
    // rather than being a transient the next repaint wipes; everything else
    // gets the generic alarm shuffle. Re-evaluated every paint — including each
    // rotation tick — so the face tracks the alert on screen.
    if (alert?.still) {
      stopAlertFlip({ hero });
      hero?.releaseExpression?.(ALERT_HOLD);
    } else if (alert?.expression) {
      stopAlertFlip({ hero });
      hero?.holdExpression?.(ALERT_HOLD, alert.expression, strengthOr(alert.strength, FACE_STRENGTH.alert));
    } else {
      hero?.releaseExpression?.(ALERT_HOLD);
      startAlertFlip({ hero });
    }
  }

  function setAlerts(next) {
    if (Array.isArray(next)) lastAlerts = next;
    // Only the alerts aimed at a group this board watches. An alert with no
    // groups belongs to no board — it still stands in the chat strip, just not
    // out here — so an unrelated condition never lights up the Whisper wall.
    // The same words twice (a board-only alert and a loud one saying the same
    // thing) are one bubble, not a rotation between two identical ones. A
    // dream is a want, not a condition - it goes in the thought bubble
    // (buddy/dream.js), never here.
    const seen = new Set(listAlert ? [listAlert.body] : []);
    alerts = lastAlerts.filter((a) => {
      if (!a || !a.body || a.dream || !groupsOverlap(a.groups, watched)) return false;
      if (seen.has(a.body)) return false;
      seen.add(a.body);
      return true;
    });
    if (listAlert) alerts.unshift(listAlert);

    if (alerts.length === 0) {
      stopCycle();
      bubble.hidden = true;
      bubble.textContent = "";
      // Nothing stands: drop both the shuffle and any held face so the pet
      // falls back to its mood.
      hero?.releaseExpression?.(ALERT_HOLD);
      stopAlertFlip({ hero });
      return;
    }

    index = 0;
    // paint() drives the pet's face (hold a named face, else the shuffle) as
    // well as the bubble, so there's no separate startAlertFlip here.
    paint();
    bubble.hidden = false;

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

  // The board's items changed: say its newest high item, if that's different.
  function setItems(items) {
    const item = newestListItem(items, "high");
    if (item) hero?.holdExpression?.(HIGH_HOLD, HIGH_FACE, FACE_STRENGTH.alert);
    else hero?.releaseExpression?.(HIGH_HOLD);
    const next = item ? { key: `list:${item.id}`, body: item.name, still: true } : null;
    if (next?.key === listAlert?.key && next?.body === listAlert?.body) return;
    listAlert = next;
    setAlerts(lastAlerts);
  }

  return { setAlerts, setTags, setItems };
}
