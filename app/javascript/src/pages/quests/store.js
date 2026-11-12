// Quest board persistence. The board lives in localStorage and every change
// lands there first; the server copy (/quests/:id/state) is pushed a moment later
// and pulled on boot and whenever the page comes back into view, so a second
// device or a cleared phone picks up where the last one left off. Whichever
// copy was changed most recently wins.
//
// Hooks — an ActionEvent or a Jil trigger — go through an outbox kept on THIS
// device only, so a tap made offline still fires once the phone is back, and
// a board adopted on another device never replays them.

import QuestRules from "./rules";
import QuestRotation from "./rotation";

const PUSH_DELAY_MS = 1500;
const RETRY_MS = 15000;

function readJSON(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch (_e) {
    return fallback;
  }
}

function writeJSON(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch (_e) { /* full or blocked */ }
}

function emptyBoard() {
  return { version: 1, updatedAt: 0, settings: { resetHour: 4 }, items: [], counts: {}, log: [] };
}

function csrf() {
  return document.querySelector('meta[name="csrf-token"]')?.content || "";
}

async function request(path, method, body) {
  const res = await fetch(path, {
    method,
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf() },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, ok: res.ok, json };
}

// Each board keeps its own copy and its own outbox: a sent hook is settled
// against the log entry that fired it, which lives on one board.
export function createStore({ boardId, onChange, onError }) {
  const BOARD_KEY = `quests:board:v1:${boardId}`;
  const OUTBOX_KEY = `quests:outbox:v1:${boardId}`;
  const STATE_PATH = `/quests/${boardId}/state`;
  let board = { ...emptyBoard(), ...readJSON(BOARD_KEY, {}) };
  // A send the last page load never heard back from is just queued again.
  const outbox = readJSON(OUTBOX_KEY, []).map(({ inFlight, ...op }) => op);
  let pushTimer = null;
  let flushing = false;

  const notify = () => onChange?.(board);

  function saveLocal() {
    writeJSON(BOARD_KEY, board);
  }

  // Every change to the board goes through here: stamped, pruned, saved,
  // repainted, and queued to the server.
  function commit() {
    board.updatedAt = Date.now();
    QuestRules.prune(board, new Date());
    QuestRotation.prune(board, QuestRules.gameDate(new Date(), QuestRules.resetHourOf(board)));
    saveLocal();
    notify();
    schedulePush();
  }

  function adopt(remote) {
    if (!remote || typeof remote !== "object") return;
    board = { ...emptyBoard(), ...remote };
    saveLocal();
    notify();
  }

  function schedulePush() {
    clearTimeout(pushTimer);
    pushTimer = setTimeout(push, PUSH_DELAY_MS);
  }

  async function push() {
    if (!navigator.onLine) return;
    try {
      const res = await request(STATE_PATH, "PUT", { data: board });
      if (res.status === 409 && (res.json.data?.updatedAt || 0) > board.updatedAt) adopt(res.json.data);
    } catch (_e) { /* offline; the next change or wake pushes again */ }
  }

  async function pull() {
    try {
      const res = await request(STATE_PATH, "GET");
      if (!res.ok) return;
      const remote = res.json.data || {};
      if ((remote.updatedAt || 0) > (board.updatedAt || 0)) adopt(remote);
      else if ((board.updatedAt || 0) > (remote.updatedAt || 0)) schedulePush();
    } catch (_e) { /* offline; the local board stands */ }
  }

  // ---------------------------------------------------------------- hooks

  function saveOutbox() {
    writeJSON(OUTBOX_KEY, outbox);
    onChange?.(board);
  }

  function enqueue(op) {
    outbox.push({ id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, ...op });
    saveOutbox();
    flush();
  }

  function hookPayload(item, hook) {
    if (hook.kind === "trigger") return { kind: "trigger", trigger: hook.trigger, data: hook.data };
    return {
      kind:  "event",
      name:  hook.name || hook.data?.quest || item?.name || "Quest",
      notes: hook.notes,
      data:  { quests: true, count: hook.data?.count },
    };
  }

  function fireHooks(entry) {
    const item = QuestRules.findItem(board, entry.item);
    entry.hooks.forEach((hook, index) => {
      enqueue({ type: "hook", entryId: entry.id, index, payload: hookPayload(item, hook) });
    });
  }

  // Takes back what an undone entry's hooks did. One still waiting in the
  // outbox is simply dropped; one already sent is reversed — its event
  // deleted, its trigger fired again as an undo.
  function reverseHooks(entry) {
    let dropped = false;
    entry.hooks.forEach((hook, index) => {
      const queued = outbox.findIndex(op => op.type === "hook" && op.entryId === entry.id && op.index === index);
      if (queued >= 0 && !outbox[queued].inFlight) {
        outbox.splice(queued, 1);
        hook.state = "cancelled";
        dropped = true;
        return;
      }
      if (hook.state === "sent") reverseSent(hook);
    });
    if (dropped) saveOutbox();
  }

  function reverseSent(hook) {
    hook.state = "reversed";
    if (hook.kind === "event" && hook.eventId) {
      enqueue({ type: "unhook", eventId: hook.eventId });
    } else if (hook.kind === "trigger") {
      enqueue({ type: "trigger", payload: { kind: "trigger", trigger: hook.trigger, data: { ...hook.data, action: "undo" } } });
    }
  }

  async function sendOp(op) {
    if (op.type === "unhook") return request(`/quests/hooks/${op.eventId}`, "DELETE");
    return request("/quests/hooks", "POST", op.payload);
  }

  // Sent one at a time, oldest first, so an undo never overtakes the hook it
  // takes back.
  async function flush() {
    if (flushing || !navigator.onLine) return;
    flushing = true;
    try {
      while (outbox.length) {
        const op = outbox[0];
        op.inFlight = true;
        let res;
        try {
          res = await sendOp(op);
        } catch (_e) {
          op.inFlight = false;
          break;
        }
        op.inFlight = false;
        if (!res.ok && res.status >= 500) break;
        outbox.shift();
        if (!res.ok) onError?.(`A quest hook was refused (${res.status}).`);
        else if (op.type === "hook") settleHook(op, res.json);
        saveOutbox();
      }
    } finally {
      flushing = false;
    }
  }

  function settleHook(op, json) {
    const entry = (board.log || []).find(e => e.id === op.entryId);
    const hook = entry?.hooks?.[op.index];
    if (!hook) return;
    hook.state = "sent";
    if (json.event_id) hook.eventId = json.event_id;
    // Undone while it was on its way: take it straight back.
    if (entry.undone) reverseSent(hook);
    commit();
  }

  setInterval(flush, RETRY_MS);
  window.addEventListener("online", () => { flush(); pull(); });

  return {
    get board() { return board; },
    get pendingHooks() { return outbox.length; },
    commit, pull, flush, fireHooks, reverseHooks,
  };
}
