// The board index (/board) is a plain server-rendered gallery, not the byte
// SPA, so it mounts no socket of its own. Two small jobs it still wants:
//
//   * Keep each card's pet face on the board's CURRENT mood. The page paints
//     the stored expression, then this follows the live expression broadcast so
//     a card is never staler than the board it stands for.
//   * Rename a board in place, without opening it. The endpoint already exists
//     (PATCH the conversation); this only surfaces it on the card.
//
// Bundled into application.js like every src/ module, so it has to no-op on
// every other page — it boots only when the index grid is on the page.

import { Monitor } from "../dashboard/cells/monitor";

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

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
    wireRename(card);
  });

  // ---- live mood ------------------------------------------------------------
  // Expression broadcasts ride the per-user `byte` channel (see
  // Buddy::ExpressionState.broadcast); each names the conversation it belongs
  // to, so a card updates only when its own board's pet changes.
  Monitor.subscribe("byte", {
    received(env) {
      const data = env?.data || {};
      if (data.kind !== "buddy_expression") return;

      const card = cards.get(String(data.conversation_id));
      if (!card) return;
      const pet = card.querySelector("[data-board-card-pet]");
      if (!pet) return;

      const faces = themes[card.dataset.buddyTheme]?.faces || {};
      const url = faces[data.expression] || faces.neutral;
      if (url) pet.style.backgroundImage = `url('${url}')`;
    },
  });

  // ---- rename ---------------------------------------------------------------
  function wireRename(card) {
    const btn = card.querySelector("[data-board-rename]");
    const form = card.querySelector("[data-board-rename-form]");
    const input = card.querySelector("[data-board-rename-input]");
    const cancel = card.querySelector("[data-board-rename-cancel]");
    const nameEl = card.querySelector("[data-board-card-name]");
    if (!btn || !form || !input) return;

    const open = () => {
      form.hidden = false;
      btn.hidden = true;
      input.focus();
      input.select();
    };
    const close = () => {
      form.hidden = true;
      btn.hidden = false;
    };

    btn.addEventListener("click", open);
    if (cancel) cancel.addEventListener("click", close);

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const name = input.value.trim();
      if (!name) return;

      try {
        const res = await fetch(card.dataset.renameUrl, {
          method: "PATCH",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-CSRF-Token": csrfToken(),
          },
          body: JSON.stringify({ name }),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        if (nameEl) nameEl.textContent = name;
        close();
      } catch (err) {
        console.warn("[board] rename failed", err);
      }
    });
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
