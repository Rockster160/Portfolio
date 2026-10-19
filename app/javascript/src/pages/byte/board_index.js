// The board index (/board) is a plain server-rendered gallery, not the byte
// SPA, so it mounts no socket of its own. One small job it still wants: keep
// each card's pet on the face its board is wearing. The page paints it, then
// this follows the live broadcasts so a card is never staler than its board.
// A held face (Whisper asleep, an alert's look — see Buddy::BoardFace) wins
// over the mood, and a dream's face over an idle mood, exactly as on the board.
//
// Bundled into application.js like every src/ module, so it has to no-op on
// every other page — it boots only when the index grid is on the page.

import { Monitor } from "../dashboard/cells/monitor";
import { faceUrlFor, IDLE_FACE } from "./buddy/face_url";
import { FACE_STRENGTH, strengthOr } from "./buddy/face_strength";

function boot() {
  const grid = document.querySelector("[data-board-index]");
  if (!grid) return;

  // The pet→faces table (keyed by theme, then expression), the same one the SPA
  // reads to warm and swap the hero's face.
  let themes = {};
  try {
    themes = JSON.parse(grid.dataset.buddyThemes || "{}");
  } catch (e) {
    themes = {};
  }

  const cards = new Map(); // conversation id (string) → card wrapper
  grid.querySelectorAll("[data-board-card]").forEach((card) => {
    cards.set(String(card.dataset.conversationId), card);
  });

  const paint = (card) => {
    const pet = card.querySelector("[data-board-card-pet]");
    if (!pet) return;

    // The strongest of the held face, the dream's and the mood (face_strength.js).
    const mood = card.dataset.moodExpression || IDLE_FACE;
    let expression = mood;
    let strength = mood === IDLE_FACE ? FACE_STRENGTH.idle : FACE_STRENGTH.mood;
    [
      [card.dataset.dreamExpression, strengthOr(card.dataset.dreamStrength, FACE_STRENGTH.dream)],
      [card.dataset.heldExpression, strengthOr(card.dataset.heldStrength, FACE_STRENGTH.alert)],
    ].forEach(([face, want]) => {
      if (face && want >= strength) {
        expression = face;
        strength = want;
      }
    });
    const url = faceUrlFor(themes[card.dataset.buddyTheme], expression);
    if (url) pet.style.backgroundImage = `url('${url}')`;
  };

  // ---- live face ------------------------------------------------------------
  // Both ride the per-user `byte` channel and name the conversation they belong
  // to: `buddy_expression` moves the mood (Buddy::ExpressionState), and
  // `board_face` the held face (Buddy::BoardFace). A transient overlay
  // ("thinking") is a moment on the board itself, not something to mirror here.
  Monitor.subscribe("byte", {
    received(env) {
      const data = env?.data || {};
      const card = cards.get(String(data.conversation_id));
      if (!card) return;

      if (data.kind === "buddy_expression" && !data.transient) {
        card.dataset.moodExpression = data.expression || "";
      } else if (data.kind === "board_face") {
        card.dataset.heldExpression = data.expression || "";
        card.dataset.heldStrength = data.strength ?? "";
        card.dataset.dreamExpression = data.dream || "";
        card.dataset.dreamStrength = data.dream_strength ?? "";
      } else {
        return;
      }
      paint(card);
    },
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
