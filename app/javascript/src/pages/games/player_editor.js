// The ordered player list with an add box - setup uses it inline, the play
// screen inside its "Players" sheet. Names are typed (no autocomplete); each
// new name adopts the colour that name had in its most recent play, unless
// someone at this table already has that colour, in which case it gets the
// first free default for this play only.
import { nextFreeColor, normalizeHex } from "./colors";
import { openColorSheet } from "./color_sheet";
import { esc } from "./util";

export function colorForName(playerColors, takenHexes, name) {
  const known = normalizeHex(playerColors[name.trim().toLowerCase()]);
  const taken = takenHexes.map((h) => normalizeHex(h));
  if (known && !taken.includes(known)) return known;
  return nextFreeColor(takenHexes);
}

// mount(container, { players, teams, getPlayerColors, onChange, onColorSheetClosed })
// `players` is mutated in place and onChange(players) fires after every edit.
export function mountPlayerEditor(container, opts) {
  const { players, onChange } = opts;

  container.innerHTML = `
    <form class="basic games-add-player" data-add-form autocomplete="off">
      <input type="text" data-add-input placeholder="Player name" enterkeyhint="done" autocapitalize="words" spellcheck="false">
      <button type="submit" class="games-btn games-btn-primary">Add</button>
    </form>
    <ul class="games-player-list" data-list></ul>
  `;
  const input = container.querySelector("[data-add-input]");
  const list = container.querySelector("[data-list]");

  container.querySelector("[data-add-form]").addEventListener("submit", (e) => {
    e.preventDefault();
    const name = input.value.trim().replace(/\s+/g, " ");
    if (!name) return;
    if (players.some((p) => p.name.toLowerCase() === name.toLowerCase())) {
      input.select();
      return;
    }
    const color = colorForName(opts.getPlayerColors(), players.map((p) => p.color), name);
    players.push({ name, color, team: "" });
    input.value = "";
    input.focus();
    changed();
  });

  function changed() {
    draw();
    onChange(players);
  }

  function draw() {
    if (players.length === 0) {
      list.innerHTML = '<li class="games-player-empty">Add players in turn order - the first one rolls first.</li>';
      return;
    }
    const teams = opts.teams && opts.teams();
    list.innerHTML = players.map((p, i) => `
      <li class="games-player-item" data-index="${i}">
        <span class="games-player-order">${i + 1}</span>
        <button type="button" class="games-player-swatch-btn" data-color aria-label="Change ${esc(p.name)}'s colour">
          <span class="games-swatch" style="background:${esc(p.color)}"></span>
        </button>
        <span class="games-player-name">${esc(p.name)}</span>
        ${teams ? `<input type="text" class="games-player-team" data-team value="${esc(p.team || "")}" placeholder="Team" autocomplete="off">` : ""}
        <button type="button" class="games-icon-btn" data-up aria-label="Move up" ${i === 0 ? "disabled" : ""}>↑</button>
        <button type="button" class="games-icon-btn" data-down aria-label="Move down" ${i === players.length - 1 ? "disabled" : ""}>↓</button>
        <button type="button" class="games-icon-btn" data-remove aria-label="Remove ${esc(p.name)}">✕</button>
      </li>
    `).join("");

    list.querySelectorAll("[data-index]").forEach((row) => {
      const i = parseInt(row.dataset.index, 10);
      row.querySelector("[data-remove]").addEventListener("click", () => { players.splice(i, 1); changed(); });
      row.querySelector("[data-up]").addEventListener("click", () => {
        [players[i - 1], players[i]] = [players[i], players[i - 1]];
        changed();
      });
      row.querySelector("[data-down]").addEventListener("click", () => {
        [players[i + 1], players[i]] = [players[i], players[i + 1]];
        changed();
      });
      row.querySelector("[data-team]")?.addEventListener("change", (e) => {
        players[i].team = e.target.value.trim();
        onChange(players);
      });
      row.querySelector("[data-color]").addEventListener("click", () => {
        openColorSheet({
          name: players[i].name,
          color: players[i].color,
          onPick: (hex) => {
            players[i].color = hex;
            changed();
            if (opts.onColorSheetClosed) opts.onColorSheetClosed();
          },
        });
      });
    });
  }

  draw();
  return { redraw: draw, focus: () => input.focus() };
}
