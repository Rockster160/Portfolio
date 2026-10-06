// The live Play page - /games/plays/:id while a play is active. Pinned to
// the viewport (never scrolls), and every recording action is one tap with
// no confirmation; the undo button is always in the same spot. Recording
// never waits on the network: the store + offline queue take the tap and
// sync behind it. Sheets (score, custom value, edit a roll, menu, players)
// live outside the re-rendered root, so a background redraw never closes one.
import { GameStore } from "./store";
import { makeActions } from "./actions";
import { api } from "./api";
import { flushQueue, loadStoreSnapshot, stuckCount } from "./offline_queue";
import { valuesFor, rollDice, parseDice, MAX_GRID_VALUES } from "./dice";
import { textColorFor } from "./colors";
import { openSheet, closeSheet } from "./sheet";
import { keypadHtml, wireKeypad } from "./keypad";
import { mountPlayerEditor } from "./player_editor";
import { esc, clock, ago, buzz } from "./util";

const ONE_OFF_DICE = ["d4", "d6", "d8", "d10", "d12", "d20", "2d6", "d100"];
const PIPS = { 1: [4], 2: [0, 8], 3: [0, 4, 8], 4: [0, 2, 6, 8], 5: [0, 2, 4, 6, 8], 6: [0, 2, 3, 5, 6, 8] };

// Fewest empty slots wins; ties prefer 4 columns (thumb-sized on a phone).
function padColumns(count) {
  if (count <= 2) return Math.max(count, 1);
  if (count <= 4) return 2;
  const options = [4, 3, 5].filter((c) => Math.ceil(count / c) <= 6);
  return options.reduce((best, c) => {
    const empty = (c - (count % c)) % c;
    const bestEmpty = (best - (count % best)) % best;
    return empty < bestEmpty ? c : best;
  }, options[0] || 5);
}

function dieHtml(face, sides) {
  if (sides === 6 && PIPS[face]) {
    const on = PIPS[face];
    return `<span class="games-die games-die-pips" aria-label="${face}">${
      Array.from({ length: 9 }, (_, i) => `<i class="${on.includes(i) ? "on" : ""}"></i>`).join("")
    }</span>`;
  }
  return `<span class="games-die games-num">${face}</span>`;
}

function boot() {
  const root = document.querySelector("[data-play-root]");
  if (!root) return;
  const bootstrap = JSON.parse(document.querySelector("#play-bootstrap")?.textContent || "null");
  if (!bootstrap) return;

  const store = new GameStore();
  const cached = loadStoreSnapshot();
  store.activePlay = (cached?.active_play?.client_uuid === bootstrap.client_uuid) ? cached.active_play : bootstrap;
  store.activePlay.rolls = store.activePlay.rolls || [];
  store.activePlay.scores = store.activePlay.scores || [];
  store.activePlay.action_log = store.activePlay.action_log || [];

  const actions = makeActions({ store });
  const finishUrl = root.dataset.finishUrl;
  const abandonUrl = root.dataset.abandonUrl;
  const indexUrl = root.dataset.indexUrl;
  const ui = { hitValue: null, hitColor: null, freshUuid: null, virtual: null, rolling: false };
  let playerColors = {};

  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/games_worker.js", { scope: "/games" }).catch(() => {});
  api.playerColors().then((colors) => { playerColors = colors || {}; }).catch(() => {});
  holdWakeLock();

  // ---------- derived state ----------

  const play = () => store.activePlay;
  const players = () => play().players || [];
  const settings = () => play().settings || {};
  const dice = () => settings().dice || null;
  const hasDice = () => !!parseDice(dice());
  const autoAdvance = () => hasDice() && settings().auto_advance !== false;
  const scoring = () => settings().scoring || "individual";
  const tracksScore = () => scoring() === "table" || (settings().win || "high") !== "none";
  const current = () => players()[play().current_player_index] || players()[0];
  const nextPlayer = () => players()[(play().current_player_index + 1) % (players().length || 1)];
  const liveScores = () => (play().scores || []).filter((s) => !s.voided_at);

  function totals() {
    const out = {};
    liveScores().forEach((s) => { out[s.player_name] = (out[s.player_name] || 0) + s.delta; });
    return out;
  }

  // Who the score sheet should point at first. With auto-advance on, the
  // card already shows the NEXT roller, but the turn in progress (roll,
  // then build/score) belongs to whoever just rolled.
  function defaultScoreTarget() {
    if (scoring() === "table") return "Table";
    const lastRoll = store.liveRolls().at(-1);
    const person = (autoAdvance() && lastRoll) ? players().find((p) => p.name === lastRoll.player_name) : current();
    if (scoring() === "teams") return person?.team || person?.name;
    return person?.name;
  }

  function scoreTargets() {
    if (scoring() === "table") return [{ key: "Table", label: "Table", color: null }];
    if (scoring() === "teams") {
      const seen = new Map();
      players().forEach((p) => {
        const key = p.team || p.name;
        if (!seen.has(key)) seen.set(key, { key, label: key, color: p.color });
      });
      return [...seen.values()];
    }
    return players().map((p) => ({ key: p.name, label: p.name, color: p.color }));
  }

  // ---------- render ----------

  function render() {
    const p = current();
    const color = p?.color || "#3987e5";
    const fg = textColorFor(color);
    const rolls = store.liveRolls();
    const sums = totals();
    // The scoreboard already shows each total large; the strip only picks the turn there.
    const showStripScores = hasDice() && tracksScore() && scoring() === "individual";
    const unsynced = stuckCount();
    const needsNext = !autoAdvance();

    root.innerHTML = `
      <header class="games-play-head">
        <a class="games-icon-btn" href="${indexUrl}" aria-label="All games">‹</a>
        <div class="games-play-title">
          <span class="games-play-name">${esc(play().name)}</span>
          <span class="games-play-meta games-num">
            <span data-clock>${clock(play().started_at)}</span>
            ${hasDice() ? `<span>${rolls.length} roll${rolls.length === 1 ? "" : "s"}</span>` : ""}
          </span>
        </div>
        <button type="button" class="games-sync" data-sync ${unsynced ? "" : "hidden"}>${unsynced} to sync</button>
        <button type="button" class="games-icon-btn" data-menu aria-label="Game menu">⋯</button>
      </header>

      <div class="games-turn">
        <div class="games-turn-card" style="background:${esc(color)};color:${fg}">
          <span class="games-turn-text">
            <span class="games-turn-kicker">${hasDice() ? "Rolling" : "Turn"}</span>
            <span class="games-turn-name">${esc(p?.name || "-")}</span>
          </span>
          ${!needsNext && players().length > 1 ? `<span class="games-turn-next">then ${esc(nextPlayer()?.name)}</span>` : ""}
        </div>
        ${needsNext && players().length > 1 ? '<button type="button" class="games-turn-next-btn" data-next>Next ›</button>' : ""}
        <button type="button" class="games-undo" data-undo aria-label="Undo">↶<small>Undo</small></button>
      </div>

      ${players().length > 1 ? `
        <div class="games-strip ${players().length > 5 ? "is-crowded" : ""}" role="group" aria-label="Who is rolling">
          ${players().map((pl, i) => `
            <button type="button" class="games-strip-player ${i === play().current_player_index ? "is-current" : ""}"
              data-turn="${i}" style="--player:${esc(pl.color)}">
              <span class="games-strip-name"><span class="games-dot" style="background:${esc(pl.color)}"></span>${esc(pl.name)}</span>
              ${showStripScores ? `<span class="games-strip-score games-num">${sums[pl.name] || 0}</span>` : ""}
            </button>
          `).join("")}
        </div>
      ` : ""}

      ${hasDice() ? recentHtml(rolls) : ""}
      ${hasDice() ? (play().dice_mode === "virtual" ? rollerHtml() : padHtml()) : boardHtml(sums)}
      ${footHtml()}
    `;
    wire();
  }

  function recentHtml(rolls) {
    const last = rolls.slice(-3).reverse();
    if (last.length === 0) {
      return `<div class="games-recent"><div class="games-recent-empty">No rolls yet</div></div>`;
    }
    return `
      <div class="games-recent">
        ${last.map((r) => {
          const pl = players().find((x) => x.name === r.player_name);
          const odd = r.dice && r.dice !== dice() ? r.dice : (r.source === "virtual" ? "🎲" : "");
          return `
            <button type="button" class="games-recent-row ${r.client_uuid === ui.freshUuid ? "is-fresh" : ""}" data-edit="${esc(r.client_uuid)}">
              <span class="games-dot" style="background:${esc(pl?.color || "#888")}"></span>
              <span class="games-recent-name">${esc(r.player_name)}</span>
              ${odd ? `<span class="games-recent-src">${esc(odd)}</span>` : ""}
              <span class="games-recent-value games-num">${r.value}</span>
              <span class="games-recent-ago games-num" data-ago="${esc(r.rolled_at)}">${ago(r.rolled_at)}</span>
            </button>
          `;
        }).join("")}
      </div>
    `;
  }

  function padHtml() {
    const values = valuesFor(dice());
    if (values.length > MAX_GRID_VALUES) {
      return `<div class="games-pad" style="--cols:1"><button type="button" class="games-key games-key-more" data-other>Enter ${esc(dice())} roll</button></div>`;
    }
    return `
      <div class="games-pad" style="--cols:${padColumns(values.length)}">
        ${values.map((v) => `
          <button type="button" class="games-key games-num ${ui.hitValue === v ? "is-hit" : ""}" data-value="${v}"
            ${ui.hitValue === v ? `style="--player:${esc(ui.hitColor)}"` : ""}>${v}</button>
        `).join("")}
      </div>
    `;
  }

  function rollerHtml() {
    const v = ui.virtual;
    const sides = parseDice(dice())?.faces;
    const body = v
      ? `
        <span class="games-roll-hint">${esc(v.player)} rolled</span>
        <span class="games-roll-faces">${v.faces.map((f) => dieHtml(f, v.sides)).join("")}</span>
        ${v.faces.length > 1 ? `<span class="games-roll-total games-num">${v.total}</span>` : ""}
        <span class="games-roll-hint">Tap to roll for ${esc(current()?.name)}</span>
      `
      : `
        <span class="games-roll-faces">${dieHtml(sides === 6 ? 5 : "?", sides)}</span>
        <span class="games-roll-hint">Tap to roll ${esc(dice())} for ${esc(current()?.name)}</span>
      `;
    return `
      <div class="games-roller">
        <button type="button" class="games-roll-btn ${ui.rolling ? "is-rolling" : ""}" data-roll>${body}</button>
      </div>
    `;
  }

  function boardHtml(sums) {
    return `
      <div class="games-board">
        ${players().map((pl, i) => `
          <button type="button" class="games-board-player ${i === play().current_player_index ? "is-current" : ""}"
            data-board="${i}" style="--player:${esc(pl.color)}">
            <span class="games-board-name">${esc(pl.name)}</span>
            ${tracksScore() && scoring() === "individual" ? `<span class="games-board-score games-num">${sums[pl.name] || 0}</span>` : ""}
          </button>
        `).join("")}
      </div>
    `;
  }

  function footHtml() {
    const buttons = [];
    if (hasDice()) buttons.push('<button type="button" class="games-btn" data-other>Other value</button>');
    if (tracksScore()) {
      const label = scoring() === "table" ? `Table · ${totals().Table || 0}` : "+ Score";
      buttons.push(`<button type="button" class="games-btn" data-score>${esc(label)}</button>`);
    }
    if (!hasDice() && !tracksScore()) return "";
    return `<div class="games-play-foot">${buttons.join("")}</div>`;
  }

  // ---------- wiring ----------

  function wire() {
    root.querySelectorAll("[data-value]").forEach((btn) => {
      btn.addEventListener("click", () => recordValue(parseInt(btn.dataset.value, 10), "button"));
    });
    root.querySelector("[data-undo]").addEventListener("click", undo);
    root.querySelector("[data-next]")?.addEventListener("click", () => { actions.advanceTurn(); buzz(); render(); });
    root.querySelectorAll("[data-turn]").forEach((btn) => {
      btn.addEventListener("click", () => { actions.setTurn(parseInt(btn.dataset.turn, 10)); render(); });
    });
    root.querySelectorAll("[data-board]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const pl = players()[parseInt(btn.dataset.board, 10)];
        if (tracksScore()) openScoreSheet(scoring() === "teams" ? (pl.team || pl.name) : pl.name);
        else { actions.setTurn(parseInt(btn.dataset.board, 10)); render(); }
      });
    });
    root.querySelectorAll("[data-edit]").forEach((btn) => {
      btn.addEventListener("click", () => openEditSheet(btn.dataset.edit));
    });
    root.querySelector("[data-roll]")?.addEventListener("click", rollVirtual);
    root.querySelector("[data-other]")?.addEventListener("click", openOtherSheet);
    root.querySelector("[data-score]")?.addEventListener("click", () => openScoreSheet());
    root.querySelector("[data-menu]").addEventListener("click", openMenuSheet);
    root.querySelector("[data-sync]")?.addEventListener("click", async () => { await actions.flushNow(); render(); });
  }

  function recordValue(value, source, extra = {}) {
    const roller = current();
    const roll = actions.recordRoll({ value, dice: extra.dice || dice(), faces: extra.faces, source });
    ui.hitValue = source === "button" ? value : null;
    ui.hitColor = roller?.color;
    ui.freshUuid = roll.client_uuid;
    render();
    // The flash belongs to this tap only - a later redraw must not replay it.
    setTimeout(() => { ui.hitValue = null; ui.freshUuid = null; }, 450);
    return roll;
  }

  function rollVirtual() {
    const roller = current();
    const { faces, total } = rollDice(dice());
    ui.virtual = { faces, total, player: roller?.name, sides: parseDice(dice())?.faces };
    ui.rolling = true;
    recordValue(total, "virtual", { faces });
    ui.rolling = false;
  }

  function undo() {
    const entry = actions.undoLast();
    if (!entry) { toast("Nothing to undo"); return; }
    if (entry.type === "roll") {
      const roll = play().rolls.find((r) => r.client_uuid === entry.client_uuid);
      if (roll) toast(`Removed ${roll.player_name}'s ${roll.value}`);
      if (ui.virtual && roll && ui.virtual.total === roll.value) ui.virtual = null;
    } else if (entry.type === "score") {
      const score = play().scores.find((s) => s.client_uuid === entry.client_uuid);
      if (score) toast(`Removed ${score.delta > 0 ? "+" : ""}${score.delta} for ${score.player_name}`);
    } else {
      toast(`Back to ${current()?.name}`);
    }
    ui.hitValue = null;
    ui.freshUuid = null;
    buzz(8);
    render();
  }

  // ---------- sheets ----------

  function openOtherSheet() {
    const who = current()?.name;
    openSheet({
      title: `Roll for ${who}`,
      body: `
        <div class="games-sheet-section">${keypadHtml({ goLabel: `Record for ${esc(who)}` })}</div>
        <div class="games-sheet-section">
          <div class="games-sheet-label">Or roll a different die once</div>
          <div class="games-dice-chips">
            ${ONE_OFF_DICE.map((d) => `<button type="button" data-oneoff="${d}">${d}</button>`).join("")}
          </div>
        </div>
      `,
      onMount(panel) {
        wireKeypad(panel, (n) => { closeSheet(); recordValue(n, "custom"); });
        panel.querySelectorAll("[data-oneoff]").forEach((btn) => {
          btn.addEventListener("click", () => {
            const spec = btn.dataset.oneoff;
            const { faces, total } = rollDice(spec);
            closeSheet();
            recordValue(total, "custom", { dice: spec, faces });
            toast(`${who} rolled ${total} on ${spec}${faces.length > 1 ? ` (${faces.join(" + ")})` : ""}`);
          });
        });
      },
    });
  }

  function openScoreSheet(preselect) {
    let target = preselect || defaultScoreTarget();
    const presets = (settings().score_presets && settings().score_presets.length) ? settings().score_presets : [1, 2, 3, 5];
    const targets = scoreTargets();

    function body(mode) {
      const sums = totals();
      const picker = targets.length > 1 ? `
        <div class="games-sheet-section">
          <div class="games-score-targets">
            ${targets.map((t) => `
              <button type="button" class="games-score-target" data-target="${esc(t.key)}"
                aria-pressed="${t.key === target}" style="--player:${esc(t.color || "")}">
                ${t.color ? `<span class="games-dot" style="background:${esc(t.color)}"></span>` : ""}
                ${esc(t.label)} <span class="games-score-total games-num">${sums[t.key] || 0}</span>
              </button>
            `).join("")}
          </div>
        </div>
      ` : `<div class="games-sheet-section games-sheet-label">Total: <span class="games-num">${sums[target] || 0}</span></div>`;

      if (mode === "keypad") {
        return `${picker}<div class="games-sheet-section">${keypadHtml({ goLabel: "Add", allowNegative: true, placeholder: "Amount" })}</div>`;
      }
      return `
        ${picker}
        <div class="games-sheet-section games-amounts">
          ${presets.slice(0, 4).map((n) => `<button type="button" class="games-amount games-num" data-amount="${n}">+${n}</button>`).join("")}
          <button type="button" class="games-amount games-num is-neg" data-amount="-1">−1</button>
          <button type="button" class="games-amount games-num is-neg" data-amount="-5">−5</button>
          <button type="button" class="games-amount" data-keypad style="grid-column: span 2; font-size:17px">Other amount</button>
        </div>
      `;
    }

    function add(delta) {
      actions.addScore({ playerName: target, delta });
      buzz();
      closeSheet();
      toast(`${delta > 0 ? "+" : ""}${delta} ${target} · ${totals()[target] || 0}`);
      render();
    }

    const sheet = openSheet({
      title: scoring() === "table" ? "Table score" : "Add points",
      body: body("presets"),
      onMount(panel) {
        panel.querySelectorAll("[data-target]").forEach((btn) => {
          btn.addEventListener("click", () => {
            target = btn.dataset.target;
            panel.querySelectorAll("[data-target]").forEach((b) => b.setAttribute("aria-pressed", b.dataset.target === target));
          });
        });
        panel.querySelectorAll("[data-amount]").forEach((btn) => {
          btn.addEventListener("click", () => add(parseInt(btn.dataset.amount, 10)));
        });
        panel.querySelector("[data-keypad]")?.addEventListener("click", () => sheet.refresh(body("keypad")));
        if (panel.querySelector("[data-display]")) wireKeypad(panel, (n) => { if (n !== 0) add(n); });
      },
    });
  }

  function openEditSheet(clientUuid) {
    const roll = play().rolls.find((r) => r.client_uuid === clientUuid);
    if (!roll) return;
    let value = roll.value;
    let playerIndex = Math.max(players().findIndex((p) => p.name === roll.player_name), 0);
    const values = valuesFor(roll.dice || dice());
    const at = new Date(roll.rolled_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

    openSheet({
      title: `Edit roll · ${at}`,
      body: `
        <div class="games-sheet-section">
          <div class="games-sheet-label">Who rolled</div>
          <div class="games-score-targets">
            ${players().map((pl, i) => `
              <button type="button" class="games-score-target" data-who="${i}" aria-pressed="${i === playerIndex}" style="--player:${esc(pl.color)}">
                <span class="games-dot" style="background:${esc(pl.color)}"></span>${esc(pl.name)}
              </button>
            `).join("")}
          </div>
        </div>
        <div class="games-sheet-section">
          <div class="games-sheet-label">Value</div>
          ${values.length && values.length <= MAX_GRID_VALUES
            ? `<div class="games-edit-values">${values.map((v) => `<button type="button" class="games-num" data-v="${v}" aria-pressed="${v === value}">${v}</button>`).join("")}</div>`
            : keypadHtml({ goLabel: "Use this value", placeholder: String(value) })}
        </div>
        <div class="games-sheet-actions">
          <button type="button" class="games-btn games-btn-primary games-btn-block" data-save>Save</button>
          <button type="button" class="games-btn games-btn-danger games-btn-block" data-delete>Delete this roll</button>
        </div>
      `,
      onMount(panel) {
        panel.querySelectorAll("[data-who]").forEach((btn) => {
          btn.addEventListener("click", () => {
            playerIndex = parseInt(btn.dataset.who, 10);
            panel.querySelectorAll("[data-who]").forEach((b) => b.setAttribute("aria-pressed", b === btn));
          });
        });
        panel.querySelectorAll("[data-v]").forEach((btn) => {
          btn.addEventListener("click", () => {
            value = parseInt(btn.dataset.v, 10);
            panel.querySelectorAll("[data-v]").forEach((b) => b.setAttribute("aria-pressed", b === btn));
          });
        });
        if (panel.querySelector("[data-display]")) wireKeypad(panel, (n) => { value = n; toast(`Value set to ${n} - tap Save`); });
        panel.querySelector("[data-save]").addEventListener("click", () => {
          const pl = players()[playerIndex];
          if (value !== roll.value || pl.name !== roll.player_name) {
            actions.editRoll(clientUuid, { value, playerName: pl.name, playerIndex });
            toast("Roll updated");
          }
          closeSheet();
          render();
        });
        panel.querySelector("[data-delete]").addEventListener("click", () => {
          actions.deleteRoll(clientUuid);
          closeSheet();
          toast(`Deleted ${roll.player_name}'s ${roll.value}`);
          render();
        });
      },
    });
  }

  function openMenuSheet() {
    const auto = settings().auto_advance !== false;
    const virtual = play().dice_mode === "virtual";
    openSheet({
      title: play().name,
      body: `
        ${hasDice() ? `
          <div class="games-sheet-section games-rows">
            <button type="button" class="games-row" data-toggle-auto>
              <span class="games-row-label">Next player after each roll</span>
              <span class="games-switch" role="switch" aria-checked="${auto}"></span>
            </button>
            <div class="games-row games-row-stack">
              <span class="games-row-label">Dice (${esc(dice())})</span>
              <div class="games-segmented">
                <button type="button" data-mode="manual" aria-pressed="${!virtual}">Real dice</button>
                <button type="button" data-mode="virtual" aria-pressed="${virtual}">Roll in the app</button>
              </div>
            </div>
          </div>
        ` : ""}
        <div class="games-sheet-section games-rows">
          <button type="button" class="games-row" data-players>
            <span class="games-row-label">Players</span>
            <span class="games-row-hint">${players().length} · reorder, add, colours ›</span>
          </button>
        </div>
        <div class="games-sheet-actions">
          <button type="button" class="games-btn games-btn-primary games-btn-block games-btn-lg" data-end>End game &amp; enter scores</button>
          <button type="button" class="games-btn games-btn-danger games-btn-block" data-abandon>Abandon game</button>
        </div>
      `,
      onMount(panel) {
        panel.querySelector("[data-toggle-auto]")?.addEventListener("click", () => {
          actions.updateSettings({ auto_advance: !(settings().auto_advance !== false) });
          render();
          openMenuSheet();
        });
        panel.querySelectorAll("[data-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            actions.setDiceMode(btn.dataset.mode);
            ui.virtual = null;
            closeSheet();
            render();
          });
        });
        panel.querySelector("[data-players]").addEventListener("click", openPlayersSheet);
        panel.querySelector("[data-end]").addEventListener("click", async (e) => {
          e.currentTarget.disabled = true;
          await actions.flushNow();
          window.location.href = finishUrl;
        });
        panel.querySelector("[data-abandon]").addEventListener("click", async () => {
          if (!window.confirm("Abandon this game? It stays in your log, without final scores.")) return;
          await actions.flushNow();
          postAndGo(abandonUrl);
        });
      },
    });
  }

  function openPlayersSheet() {
    const editing = players().map((p) => ({ ...p }));
    openSheet({
      title: "Players",
      body: '<div data-editor></div><div class="games-sheet-actions" style="margin-top:16px"><button type="button" class="games-btn games-btn-primary games-btn-block" data-done>Done</button></div>',
      onClose: render,
      onMount(panel) {
        mountPlayerEditor(panel.querySelector("[data-editor]"), {
          players: editing,
          teams: () => scoring() === "teams",
          getPlayerColors: () => playerColors,
          onChange: (list) => { if (list.length) actions.setPlayers(list); },
          onColorSheetClosed: openPlayersSheet,
        });
        panel.querySelector("[data-done]").addEventListener("click", closeSheet);
      },
    });
  }

  // ---------- chrome ----------

  let toastTimer = null;
  function toast(text) {
    let el = document.querySelector(".games-toast");
    if (!el) {
      el = document.createElement("div");
      el.className = "games-toast";
      el.setAttribute("role", "status");
      document.querySelector(".games-app").append(el);
    }
    el.textContent = text;
    el.classList.add("is-on");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("is-on"), 1800);
  }

  function postAndGo(url) {
    const form = document.createElement("form");
    form.method = "post";
    form.action = url;
    const token = document.createElement("input");
    token.type = "hidden";
    token.name = "authenticity_token";
    token.value = api.csrfToken();
    form.append(token);
    document.body.append(form);
    form.submit();
  }

  render();

  setInterval(() => {
    const clockEl = root.querySelector("[data-clock]");
    if (clockEl) clockEl.textContent = clock(play().started_at);
    root.querySelectorAll("[data-ago]").forEach((el) => { el.textContent = ago(el.dataset.ago); });
    const sync = root.querySelector("[data-sync]");
    if (sync) {
      const n = stuckCount();
      sync.hidden = n === 0;
      sync.textContent = `${n} to sync`;
    }
  }, 1000);

  const tryFlush = () => flushQueue({ csrfToken: api.csrfToken() }).catch(() => {});
  window.addEventListener("online", tryFlush);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tryFlush(); });
  setInterval(tryFlush, 30000);
}

let wakeLock = null;
async function holdWakeLock() {
  if (!("wakeLock" in navigator)) return;
  const acquire = async () => {
    try { wakeLock = await navigator.wakeLock.request("screen"); } catch (e) { /* denied - the game still works */ }
  };
  await acquire();
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && (!wakeLock || wakeLock.released)) acquire();
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
