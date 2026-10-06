// /games/new - pick a game, enter players in turn order, Start. Picking a
// saved game loads its settings and folds them into a one-line summary;
// a new name opens the settings so they get set once. Start saves the
// settings to the game, creates the play over fetch (the play's uuid is
// minted here), then does a REAL navigation to the play's URL.
import { api } from "./api";
import { mountPlayerEditor } from "./player_editor";
import { parseDice } from "./dice";
import { esc, uuid } from "./util";

const DICE_CHOICES = [
  { value: "", label: "None" },
  { value: "1d6", label: "1d6" },
  { value: "2d6", label: "2d6" },
  { value: "1d20", label: "1d20" },
];
const SCORINGS = [
  { value: "individual", label: "Each player" },
  { value: "teams", label: "Teams" },
  { value: "table", label: "One table score" },
];
const WINS = [
  { value: "high", label: "Highest" },
  { value: "low", label: "Lowest" },
  { value: "none", label: "No winner" },
];

function summarize(s, diceMode) {
  const parts = [];
  if (s.dice) {
    parts.push(`${s.dice}${diceMode === "virtual" ? " rolled in the app" : ""}`);
    if (s.auto_advance === false) parts.push("manual Next");
  } else {
    parts.push("No dice");
  }
  if (s.scoring === "teams") parts.push("teams");
  if (s.scoring === "table") parts.push("one table score");
  if (s.win === "low") parts.push("lowest wins");
  if (s.win === "high" && s.scoring !== "table") parts.push("highest wins");
  if (s.win === "none" && s.scoring !== "table") parts.push("no score");
  return parts.join(" · ");
}

function boot() {
  const root = document.querySelector("[data-new-game-root]");
  if (!root) return;

  const templates = JSON.parse(root.querySelector("[data-games-templates-json]").textContent || "[]");
  const state = {
    templateId: null,
    settings: { dice: "2d6", scoring: "individual", win: "high", auto_advance: true },
    diceMode: "manual",
    settingsOpen: false,
    diceOther: false,
    players: [],
  };
  let playerColors = {};
  api.playerColors().then((colors) => { playerColors = colors || {}; }).catch(() => {});

  const nameInput = root.querySelector("[data-games-template-input]");
  const chipsEl = root.querySelector("[data-games-template-chips]");
  const newHint = root.querySelector("[data-games-new-hint]");
  const settingsEl = root.querySelector("[data-games-settings]");
  const startBtn = root.querySelector("[data-games-start]");
  const countEl = root.querySelector("[data-games-player-count]");

  // ---------- game picker ----------

  function exactTemplate(name) {
    const n = name.trim().toLowerCase();
    return n ? templates.find((t) => t.name.toLowerCase() === n) : null;
  }

  // A picked game shows only its own chip (tap it to pick another); with
  // nothing typed, the eight most recently played plus "More"; typing
  // filters across every saved game.
  let showAllChips = false;
  function drawChips() {
    const q = nameInput.value.trim().toLowerCase();
    const selected = templates.find((t) => t.id === state.templateId);
    let matches;
    let more = 0;
    if (selected) matches = [selected];
    else if (q) matches = templates.filter((t) => t.name.toLowerCase().includes(q));
    else {
      matches = showAllChips ? templates : templates.slice(0, 8);
      more = templates.length - matches.length;
    }
    chipsEl.innerHTML = matches.map((t) => `
      <button type="button" class="games-chip" data-template="${t.id}" aria-pressed="${t.id === state.templateId}">
        ${esc(t.name)}${t.id === state.templateId ? " ✕" : ""}
      </button>
    `).join("") + (more ? `<button type="button" class="games-chip" data-more>+${more} more</button>` : "");
    chipsEl.hidden = matches.length === 0 && !more;
    chipsEl.querySelectorAll("[data-template]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const t = templates.find((x) => String(x.id) === btn.dataset.template);
        if (t.id === state.templateId) clearTemplate();
        else selectTemplate(t);
      });
    });
    chipsEl.querySelector("[data-more]")?.addEventListener("click", () => { showAllChips = true; drawChips(); });

    const typed = nameInput.value.trim();
    newHint.hidden = !(typed && !state.templateId);
    newHint.textContent = `New game: “${typed}” - set it up once below and it's saved for next time.`;
  }

  function selectTemplate(t) {
    state.templateId = t.id;
    nameInput.value = t.name;
    state.settings = {
      dice: t.dice || "",
      scoring: t.scoring || "individual",
      win: t.win || "high",
      auto_advance: t.auto_advance !== false,
    };
    state.settingsOpen = false;
    state.diceOther = !!t.dice && !DICE_CHOICES.some((d) => d.value === t.dice);
    nameInput.blur();
    refresh();
  }

  function clearTemplate() {
    state.templateId = null;
    nameInput.value = "";
    refresh();
    nameInput.focus();
  }

  nameInput.addEventListener("input", () => {
    const exact = exactTemplate(nameInput.value);
    if (exact) {
      state.templateId = exact.id;
      state.settings = { dice: exact.dice || "", scoring: exact.scoring, win: exact.win, auto_advance: exact.auto_advance !== false };
      state.settingsOpen = false;
    } else {
      if (state.templateId) state.settingsOpen = true;
      state.templateId = null;
      if (nameInput.value.trim()) state.settingsOpen = true;
    }
    refresh();
  });
  nameInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); nameInput.blur(); }
  });

  // ---------- settings ----------

  function segmented(name, options, value) {
    return `
      <div class="games-segmented" data-seg="${name}">
        ${options.map((o) => `<button type="button" data-v="${esc(o.value)}" aria-pressed="${o.value === value}">${esc(o.label)}</button>`).join("")}
      </div>
    `;
  }

  function drawSettings() {
    const s = state.settings;
    if (!state.settingsOpen) {
      settingsEl.innerHTML = `
        <div class="games-field-label">Setup</div>
        <button type="button" class="games-settings-summary" data-open-settings>
          <span class="games-settings-summary-text">${esc(summarize(s, state.diceMode))}</span>
          <span class="games-settings-summary-edit">Change</span>
        </button>
      `;
      settingsEl.querySelector("[data-open-settings]").addEventListener("click", () => { state.settingsOpen = true; drawSettings(); });
      return;
    }

    const standard = !state.diceOther && DICE_CHOICES.some((d) => d.value === s.dice);
    const diceValue = standard ? s.dice : "other";
    settingsEl.innerHTML = `
      <div class="games-field-label">Setup</div>
      <div class="games-settings-panel">
        <div>
          <div class="games-setting-label">Dice rolled each turn</div>
          ${segmented("dice", [...DICE_CHOICES, { value: "other", label: "Other" }], diceValue)}
          <input type="text" class="games-dice-other" data-dice-other value="${standard ? "" : esc(s.dice)}"
            placeholder="e.g. 3d6 or 1d8" autocomplete="off" autocapitalize="off" spellcheck="false" ${standard ? "hidden" : ""}>
        </div>
        ${s.dice ? `
          <div>
            <div class="games-setting-label">Rolling</div>
            ${segmented("mode", [{ value: "manual", label: "Real dice" }, { value: "virtual", label: "Roll in the app" }], state.diceMode)}
          </div>
          <div class="games-setting-inline">
            <span class="games-setting-text">Next player after each roll<br><span class="games-setting-sub">Turn it off to score before passing the turn</span></span>
            <button type="button" class="games-switch" role="switch" aria-checked="${s.auto_advance !== false}" data-auto aria-label="Next player after each roll"></button>
          </div>
        ` : ""}
        <div>
          <div class="games-setting-label">Scoring</div>
          ${segmented("scoring", SCORINGS, s.scoring)}
        </div>
        ${s.scoring !== "table" ? `
          <div>
            <div class="games-setting-label">Who wins</div>
            ${segmented("win", WINS, s.win)}
          </div>
        ` : ""}
      </div>
    `;

    settingsEl.querySelectorAll("[data-seg]").forEach((seg) => {
      seg.querySelectorAll("[data-v]").forEach((btn) => {
        btn.addEventListener("click", () => {
          const v = btn.dataset.v;
          const key = seg.dataset.seg;
          if (key === "dice") {
            state.diceOther = v === "other";
            if (state.diceOther) {
              if (DICE_CHOICES.some((d) => d.value === s.dice)) s.dice = "";
              drawSettings();
              validate();
              settingsEl.querySelector("[data-dice-other]").focus();
              return;
            }
            s.dice = v;
          } else if (key === "mode") {
            state.diceMode = v;
          } else {
            s[key] = v;
          }
          drawSettings();
          validate();
        });
      });
    });
    settingsEl.querySelector("[data-dice-other]")?.addEventListener("input", (e) => {
      s.dice = e.target.value.trim().toLowerCase().replace(/^d/, "1d");
      validate();
    });
    settingsEl.querySelector("[data-dice-other]")?.addEventListener("change", () => drawSettings());
    settingsEl.querySelector("[data-auto]")?.addEventListener("click", () => {
      s.auto_advance = !(s.auto_advance !== false);
      drawSettings();
    });
    // Teams need a team box on every player row.
    editor.redraw();
  }

  // ---------- players ----------

  const editor = mountPlayerEditor(root.querySelector("[data-games-player-editor]"), {
    players: state.players,
    teams: () => state.settings.scoring === "teams",
    getPlayerColors: () => playerColors,
    onChange: () => validate(),
  });

  // ---------- start ----------

  function validate() {
    const name = nameInput.value.trim();
    const diceOk = !state.settings.dice || !!parseDice(state.settings.dice);
    countEl.textContent = state.players.length ? `${state.players.length}` : "";
    startBtn.disabled = !name || state.players.length === 0 || !diceOk;
    if (!name) startBtn.textContent = "Pick a game";
    else if (!diceOk) startBtn.textContent = "Dice must look like 2d6";
    else if (state.players.length === 0) startBtn.textContent = "Add a player";
    else startBtn.textContent = `Start ${name}`;
  }

  function refresh() {
    drawChips();
    drawSettings();
    validate();
  }

  startBtn.addEventListener("click", async () => {
    const errorEl = root.querySelector("[data-games-setup-error]");
    errorEl.hidden = true;
    startBtn.disabled = true;
    startBtn.textContent = "Starting…";

    const name = nameInput.value.trim();
    const settings = { ...state.settings, dice: state.settings.dice || null };
    const clientUuid = uuid();
    try {
      const template = await api.upsertTemplate({ id: state.templateId, name, ...settings, dice: settings.dice || "" });
      const res = await fetch(`/games/plays/${clientUuid}/sync`, {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": api.csrfToken() },
        body: JSON.stringify({
          play: {
            game_template_id: template.id, name, settings, dice_mode: settings.dice ? state.diceMode : "manual",
            players: state.players, started_at: new Date().toISOString(),
          },
        }),
      });
      if (!res.ok) throw new Error(`sync -> ${res.status}`);
      const body = await res.json();
      window.location.href = `/games/plays/${body.play.id}`;
    } catch (e) {
      errorEl.textContent = "Couldn't start - check the connection and tap Start again.";
      errorEl.hidden = false;
      validate();
    }
  });

  const preselected = templates.find((t) => String(t.id) === root.dataset.preselectedId);
  if (preselected) selectTemplate(preselected);
  else refresh();
  if (preselected) editor.focus();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
