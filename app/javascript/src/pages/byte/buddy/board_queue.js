// A board's presses, written down BEFORE they're sent, the way the Chores
// page's offline queue works: a tap is kept in localStorage with the moment it
// happened, so a board with no connection still takes presses, a reload or a
// dead tab doesn't lose them, and they go out in order once the server can be
// reached. Each entry carries what the press should look like (see
// chore_board.js#withQueued), so the screen shows it until the server answers.
//
// A press is sent until it lands or the server refuses it outright. A 5xx (or
// being signed out) keeps it and tries again with a growing wait, and the rest
// still go out behind it. No connection at all stops the pass where it is, so
// the presses after it wait and land in the order they were pressed. A completion carries `client_completed_at` and a
// `client_mutation_id`, so one replayed after its answer was lost is credited
// once, at the time it was pressed.
//
// A press that only RUNS something (a routine, a task) has no timestamp to
// carry, and running it an hour late would be its own surprise, so those are
// let go after ACTION_TTL_MS.

export const ACTION_TTL_MS = 10 * 60 * 1000;
const RETRY_FIRST_MS = 2000;
const RETRY_MAX_MS = 60000;

// Kinds that only run something now; everything else records a chore.
const ACTIONS = new Set(["trigger", "task"]);

function newId() {
  if (globalThis.crypto?.randomUUID) return `q-${globalThis.crypto.randomUUID()}`;
  return `q-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`;
}

function defaultStorage() {
  try {
    return globalThis.window?.localStorage || globalThis.localStorage || null;
  } catch (_) {
    return null;
  }
}

// `send(entry)` resolves to { ok: true, data } when the server took it,
// { ok: false, retry: true } to keep it for later, or { ok: false } when the
// server refused it and it should be dropped. A throw means the server
// couldn't be reached.
// `onDone(entry, data, landed)` runs for each one that's finished: landed with
// the server's answer, or refused/expired with `landed` false. `onChange()`
// runs after anything about the queue moved.
export function createBoardQueue({
  key,
  send,
  onDone = () => {},
  onChange = () => {},
  storage = defaultStorage(),
  now = () => Date.now(),
  online = () => globalThis.navigator?.onLine !== false,
  setTimer = (fn, ms) => setTimeout(fn, ms),
}) {
  // Storage can be missing or refuse writes (private mode); the queue still
  // works for the life of the page then.
  let memory = [];
  let running = null;
  let again = false;
  let retryTimer = null;
  let retryDelay = RETRY_FIRST_MS;
  let sending = null;

  function load() {
    if (!storage) return memory.slice();
    try {
      const list = JSON.parse(storage.getItem(key) || "[]");
      return Array.isArray(list) ? list : [];
    } catch (_) {
      return memory.slice();
    }
  }

  function save(list) {
    memory = list.slice();
    try {
      storage?.setItem(key, JSON.stringify(list));
    } catch (_) {}
  }

  function expired(entry) {
    return ACTIONS.has(entry.kind) && now() - Date.parse(entry.queued_at) > ACTION_TTL_MS;
  }

  function drop(qid) {
    save(load().filter((e) => e.qid !== qid));
  }

  function markLoud(qid) {
    const list = load();
    let changed = false;
    list.forEach((e) => {
      if ((qid == null || e.qid === qid) && !e.loud) {
        e.loud = true;
        changed = true;
      }
    });
    if (changed) save(list);
  }

  function scheduleRetry() {
    if (retryTimer) return;
    retryTimer = setTimer(() => {
      retryTimer = null;
      flush();
    }, retryDelay);
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
  }

  async function flushOnce() {
    const snapshot = load();
    if (!snapshot.length) return;
    if (!online()) {
      markLoud(null);
      onChange();
      return;
    }

    let waiting = false;
    for (const entry of snapshot) {
      // Undone, or dropped elsewhere, since the snapshot was taken.
      if (!load().some((e) => e.qid === entry.qid)) continue;
      if (expired(entry)) {
        drop(entry.qid);
        onDone(entry, null, false);
        continue;
      }

      sending = entry.qid;
      onChange();
      let outcome;
      try {
        outcome = await send(entry);
      } catch (_) {
        // Unreachable: this one and everything after it wait.
        sending = null;
        markLoud(entry.qid);
        onChange();
        scheduleRetry();
        return;
      }
      sending = null;

      if (outcome?.ok) {
        retryDelay = RETRY_FIRST_MS;
        drop(entry.qid);
        onDone(entry, outcome.data ?? null, true);
        continue;
      }
      if (!outcome?.retry) {
        drop(entry.qid);
        onDone(entry, null, false);
        continue;
      }

      // Kept for another go; the rest still go out.
      markLoud(entry.qid);
      waiting = true;
    }
    if (waiting) scheduleRetry();
    onChange();
  }

  // Single-flight: a press during a flush asks for one more pass after it, and
  // every caller's promise settles once the queue has had all of them.
  function flush() {
    if (running) {
      again = true;
      return running;
    }
    running = (async () => {
      try {
        do {
          again = false;
          await flushOnce();
        } while (again);
      } finally {
        running = null;
      }
    })();
    return running;
  }

  return {
    entries: load,
    // Written down first, then sent. Resolves once it (and anything queued with
    // it) has been tried.
    enqueue(entry) {
      const full = {
        ...entry,
        qid: entry.qid || newId(),
        queued_at: entry.queued_at || new Date(now()).toISOString(),
        // Pressed with no connection: worth saying so from the start.
        loud: !!entry.loud || !online(),
      };
      save([...load(), full]);
      onChange();
      return flush();
    },
    // Taken back before it was sent (an undo of a press still waiting).
    // False when it's on its way right now and has to be undone on the server.
    remove(qid) {
      if (sending === qid) return false;
      if (!load().some((e) => e.qid === qid)) return false;
      drop(qid);
      onChange();
      return true;
    },
    flush,
  };
}
