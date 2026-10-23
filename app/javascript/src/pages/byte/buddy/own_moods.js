// A look Jil holds on the person's OWN pet, in their own threads: `Buddy.mood`
// raised with no groups. One with groups is aimed at the boards those groups
// name (buddy/board_alert.js); one with none belongs to no board, so it is
// worn here instead, each under its own hold, for as long as it stands.
//
// Its strength decides how much it shows. A low one (under a real mood's) is
// a resting look the pet falls back to between replies: any [[mood:]] still
// wins while it lasts, and the look comes back once the face goes idle.
//
// Off on a board, which is the house's pet and not anybody's own.

import { FACE_STRENGTH, strengthOr } from "./face_strength.js";

const HOLD = "own-mood:";

export function initOwnMoods({ hero, board }) {
  let held = new Set();

  function setAlerts(alerts) {
    if (board || !Array.isArray(alerts)) return;

    const next = new Set();
    alerts.forEach((a) => {
      if (!a || a.body || a.dream || !a.faces) return;
      if (Array.isArray(a.groups) && a.groups.length) return;

      const key = HOLD + a.key;
      next.add(key);
      hero?.holdExpression?.(key, a.faces, strengthOr(a.strength, FACE_STRENGTH.alert));
    });
    held.forEach((key) => {
      if (!next.has(key)) hero?.releaseExpression?.(key);
    });
    held = next;
  }

  return { setAlerts };
}
