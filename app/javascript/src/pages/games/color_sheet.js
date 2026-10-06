// The colour picker for one player: the default set as one-tap swatches,
// the native picker, and a hex field - any of them updates the live
// preview chip, and Done commits. Used by setup and by mid-game player edits.
import { openSheet, closeSheet } from "./sheet";
import { DEFAULT_COLORS, normalizeHex, textColorFor } from "./colors";
import { esc } from "./util";

export function openColorSheet({ name, color, onPick }) {
  let chosen = normalizeHex(color) || DEFAULT_COLORS[0];

  const body = `
    <div class="games-color-preview" data-preview></div>
    <div class="games-color-grid">
      ${DEFAULT_COLORS.map((c) => `
        <button type="button" data-hex="${c}" style="background:${c}" aria-label="${c}"></button>
      `).join("")}
    </div>
    <div class="games-color-custom">
      <label class="games-color-native" aria-label="Pick any colour">
        <input type="color" data-native>
      </label>
      <input type="text" data-hex-input placeholder="#d6609a" maxlength="7" autocomplete="off" autocapitalize="off" spellcheck="false">
    </div>
    <div class="games-sheet-actions" style="margin-top:16px">
      <button type="button" class="games-btn games-btn-primary games-btn-block" data-done>Done</button>
    </div>
  `;

  openSheet({
    title: `${name}'s colour`,
    body,
    onMount(panel) {
      const preview = panel.querySelector("[data-preview]");
      const native = panel.querySelector("[data-native]");
      const hexInput = panel.querySelector("[data-hex-input]");

      function show({ fromHex = false } = {}) {
        preview.style.background = chosen;
        preview.style.color = textColorFor(chosen);
        preview.innerHTML = esc(name);
        native.value = chosen;
        if (!fromHex) hexInput.value = chosen;
        panel.querySelectorAll("[data-hex]").forEach((b) => {
          b.setAttribute("aria-pressed", b.dataset.hex === chosen ? "true" : "false");
        });
      }

      panel.querySelectorAll("[data-hex]").forEach((b) => {
        b.addEventListener("click", () => { chosen = b.dataset.hex; show(); });
      });
      native.addEventListener("input", () => { chosen = native.value.toLowerCase(); show(); });
      hexInput.addEventListener("input", () => {
        const hex = normalizeHex(hexInput.value);
        if (hex) { chosen = hex; show({ fromHex: true }); }
      });
      // Close first: onPick may open another sheet (back to Players), and
      // closing after would shut that one instead.
      panel.querySelector("[data-done]").addEventListener("click", () => {
        closeSheet();
        onPick(chosen);
      });
      show();
    },
  });
}
