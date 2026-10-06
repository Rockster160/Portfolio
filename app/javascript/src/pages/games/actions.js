import { enqueue, saveStoreSnapshot, flushQueue } from "./offline_queue";
import { api } from "./api";
import { uuid, buzz } from "./util";

// Debounced flush - every mutation calls this, but a burst of taps (undo,
// re-roll, undo again) shouldn't open a connection per tap. 400ms is short
// enough that "unsynced" never lingers once the network is back.
let flushTimer = null;
function scheduleFlush() {
  clearTimeout(flushTimer);
  flushTimer = setTimeout(() => flushQueue({ csrfToken: api.csrfToken() }).catch(() => {}), 400);
}

// Mutations for the LIVE play page only - starting a play (new_game.js) and
// ending one (a plain server <form>, see games/finish.html.erb) are real
// navigations and don't go through here.
export function makeActions({ store }) {
  function save() {
    saveStoreSnapshot(store);
  }

  function currentPlayer() {
    const play = store.activePlay;
    return play?.players?.[play.current_player_index] || null;
  }

  function autoAdvance() {
    return store.activePlay?.settings?.auto_advance !== false;
  }

  function nextIndex() {
    const play = store.activePlay;
    const count = (play.players || []).length;
    return count ? (play.current_player_index + 1) % count : 0;
  }

  function pushPlayPatch(patch) {
    enqueue({ kind: "play", play_client_uuid: store.activePlay.client_uuid, payload: patch });
  }

  // One tap: record for the current player, advance if auto-advance is on,
  // buzz. Logged so undo can reverse BOTH the roll and the advance in one
  // tap, matching the one-tap-to-fix-a-mistake rule on the play screen.
  function recordRoll({ value, dice, faces, source, playerName, playerIndex } = {}) {
    const play = store.activePlay;
    const player = playerName != null ? { name: playerName, index: playerIndex } : { name: currentPlayer()?.name, index: play.current_player_index };
    const roll = {
      client_uuid: uuid(), player_name: player.name, player_index: player.index ?? play.current_player_index,
      value, dice: dice || play.settings?.dice, faces: faces || null, source: source || "button",
      rolled_at: new Date().toISOString(),
    };
    store.addRoll(roll);
    enqueue({ kind: "roll", play_client_uuid: play.client_uuid, payload: roll });

    const willAdvance = playerName == null && autoAdvance();
    const prevIndex = play.current_player_index;
    if (willAdvance) {
      const next = nextIndex();
      store.patchActivePlay({ current_player_index: next });
      pushPlayPatch({ current_player_index: next });
    }
    play.action_log.push({ type: "roll", client_uuid: roll.client_uuid, advanced: willAdvance, prev_index: prevIndex });
    save();
    scheduleFlush();
    buzz();
    return roll;
  }

  function advanceTurn() {
    setTurn(nextIndex());
  }

  // "Chelsea's rolling instead" - jump the turn to any player. Logged like a
  // Next so the same undo button steps it back.
  function setTurn(index) {
    const play = store.activePlay;
    const prevIndex = play.current_player_index;
    if (index === prevIndex) return;
    store.patchActivePlay({ current_player_index: index });
    pushPlayPatch({ current_player_index: index });
    play.action_log.push({ type: "advance", prev_index: prevIndex });
    save();
    scheduleFlush();
  }

  // Fixing a past roll: rolls are append-only on the server (upserted by
  // client_uuid), so an edit voids the old row and records a replacement
  // carrying the ORIGINAL rolled_at, then repoints the undo log at it - undo
  // keeps meaning "the last thing I did at the table", not "the edit".
  function editRoll(clientUuid, { value, playerName, playerIndex }) {
    const play = store.activePlay;
    const old = play.rolls.find((r) => r.client_uuid === clientUuid);
    if (!old) return;
    const replacement = {
      ...old, client_uuid: uuid(), value, player_name: playerName, player_index: playerIndex,
      source: old.source === "virtual" && value === old.value ? old.source : "custom",
      faces: value === old.value ? old.faces : null, voided_at: null,
    };
    store.voidByUuid("roll", clientUuid);
    enqueue({ kind: "void", play_client_uuid: play.client_uuid, payload: { kind: "roll", client_uuid: clientUuid } });
    insertRoll(replacement);
    enqueue({ kind: "roll", play_client_uuid: play.client_uuid, payload: replacement });
    play.action_log.forEach((entry) => {
      if (entry.type === "roll" && entry.client_uuid === clientUuid) entry.client_uuid = replacement.client_uuid;
    });
    save();
    scheduleFlush();
  }

  function deleteRoll(clientUuid) {
    const play = store.activePlay;
    store.voidByUuid("roll", clientUuid);
    enqueue({ kind: "void", play_client_uuid: play.client_uuid, payload: { kind: "roll", client_uuid: clientUuid } });
    play.action_log = play.action_log.filter((e) => !(e.type === "roll" && e.client_uuid === clientUuid));
    save();
    scheduleFlush();
  }

  // Keep rolls in time order so "the last three" stays right after an edit.
  function insertRoll(roll) {
    const rolls = store.activePlay.rolls;
    const at = rolls.findIndex((r) => r.rolled_at > roll.rolled_at);
    if (at === -1) rolls.push(roll);
    else rolls.splice(at, 0, roll);
  }

  function updateSettings(patch) {
    const settings = { ...(store.activePlay.settings || {}), ...patch };
    store.patchActivePlay({ settings });
    pushPlayPatch({ settings: patch });
    save();
    scheduleFlush();
  }

  function setDiceMode(mode) {
    store.patchActivePlay({ dice_mode: mode });
    pushPlayPatch({ dice_mode: mode });
    save();
    scheduleFlush();
  }

  function addScore({ playerName, delta }) {
    const play = store.activePlay;
    const score = { client_uuid: uuid(), player_name: playerName, delta, entered_at: new Date().toISOString() };
    store.addScore(score);
    enqueue({ kind: "score", play_client_uuid: play.client_uuid, payload: score });
    play.action_log.push({ type: "score", client_uuid: score.client_uuid });
    save();
    scheduleFlush();
  }

  // Always the same button, always undoes the LAST thing - a roll (and the
  // advance it caused, if any), a score, or a bare Next.
  function undoLast() {
    const play = store.activePlay;
    const entry = play.action_log?.pop() || reconstructLastRoll();
    if (!entry) return null;

    if (entry.type === "roll") {
      store.voidByUuid("roll", entry.client_uuid);
      enqueue({ kind: "void", play_client_uuid: play.client_uuid, payload: { kind: "roll", client_uuid: entry.client_uuid } });
      if (entry.advanced) {
        store.patchActivePlay({ current_player_index: entry.prev_index });
        pushPlayPatch({ current_player_index: entry.prev_index });
      }
    } else if (entry.type === "score") {
      store.voidByUuid("score", entry.client_uuid);
      enqueue({ kind: "void", play_client_uuid: play.client_uuid, payload: { kind: "score", client_uuid: entry.client_uuid } });
    } else if (entry.type === "advance") {
      store.patchActivePlay({ current_player_index: entry.prev_index });
      pushPlayPatch({ current_player_index: entry.prev_index });
    }
    save();
    scheduleFlush();
    return entry;
  }

  // The undo log lives in this tab's memory and snapshot; a fresh device or
  // a cleared cache starts with none. Undo still has to work then: take the
  // newest live roll and hand the turn back to whoever rolled it.
  function reconstructLastRoll() {
    const last = store.liveRolls().at(-1);
    if (!last) return null;
    return {
      type: "roll", client_uuid: last.client_uuid,
      advanced: autoAdvance(), prev_index: last.player_index ?? store.activePlay.current_player_index,
    };
  }

  // Removing someone mid-game must not leave the turn pointing past the end
  // of the list (or at a different person than before).
  function setPlayers(players) {
    const play = store.activePlay;
    const currentName = play.players[play.current_player_index]?.name;
    let index = players.findIndex((p) => p.name === currentName);
    if (index === -1) index = Math.min(play.current_player_index, Math.max(players.length - 1, 0));
    store.patchActivePlay({ players: players.map((p) => ({ ...p })), current_player_index: index });
    pushPlayPatch({ players: store.activePlay.players, current_player_index: index });
    save();
    scheduleFlush();
  }

  function flushNow() {
    clearTimeout(flushTimer);
    return flushQueue({ csrfToken: api.csrfToken() }).catch(() => {});
  }

  return {
    recordRoll, advanceTurn, setTurn, addScore, undoLast, setPlayers, editRoll, deleteRoll,
    updateSettings, setDiceMode, flushNow,
  };
}
