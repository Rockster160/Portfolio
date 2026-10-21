// The chore board. The kiosk's surface, with one group of chores on it as
// circles big enough to press on the way past instead of the routine pad.
//
// Three things make it its own file rather than a branch inside kiosk.js:
//
//   * a cell has STATE (how many of today's target are done, whether it's been
//     waved off, whether the occurrence was let go) where a routine button has
//     none, so it repaints rather than just existing;
//   * the set changes under the screen all day — a tap from a phone, somebody
//     else in the household, the 4am reset swapping yesterday's done chores for
//     today's due ones — so it rides the chores broadcast rail as well as its
//     own fetch;
//   * every press goes to an endpoint /chores/today already has. Nothing here
//     is board-specific except the sizes and the line the pet says over it.
//
// What a press does NOT do is write anything Buddy-shaped. The completion is
// an ordinary ChoreCompletion through the ordinary controller; the encouraging
// line is a second, separate call that is allowed to fail.

import { Monitor } from "../../dashboard/cells/monitor";
import { boardOwnerId, feedOwnerMatches } from "./board_scope";
import { initBoardChorePicker } from "./board_chore_picker";
import { paceFromMeta, dreamSummary } from "./dream";
import { createBoardQueue } from "./board_queue";
import { initBoardTaskButtons, rowHandle, sortableRows } from "./board_task_buttons";
import { setButtonText, splitGraphemes } from "../../../button_text";
import { parseDuration, formatDurationShort, humanizeSeconds } from "../../timers/duration.js";
import { DURATION_PLACEHOLDER, durationRead } from "./routine_step";

// Both skips, and the difference is the whole feature. `dismiss` leaves the
// chore's cycle exactly where it was and simply stops asking for a while;
// `skip` lets the OCCURRENCE go, which settles it until the schedule brings it
// round again. Neither credits anyone and neither is paid.
const COMPLETE_URL = (id) => `/chores/items/${id}/completion`;
const DISMISS_URL = (id) => `/chores/items/${id}/dismiss`;
const SKIP_URL = (id) => `/chores/items/${id}/skip`;

// A trigger cell fires a routine. Same endpoint and same no-model-turn replay
// the kiosk's routine pad uses, so a trigger pressed on a board does exactly
// what the same button does on the wall tablet next to it.
const RUN_URL = (id) => `/buddy/routines/${id}/run`;

// A credit button's press: completes its chore crediting its chosen member.
const PRESS_URL = (id) => `/byte/board/buttons/${id}/press`;

// A task button's press: runs its Jil task (the Whisper fed/quiet/nap/gone
// controls). Fire-and-forget — the task reports back through the board's live
// feeds (rings, a sound, an alert), not this response.
const TASK_PRESS_URL = (id) => `/byte/board/tasks/${id}/press`;

// A list item's circle: POST checks it off its list, DELETE puts it back.
const LIST_CHECK_URL = (id) => `/byte/board/list_items/${id}/check`;

// A task press is the pet DOING something, so it puts on its working face for
// a moment: one of these.
const TASK_FACES = ["nerd", "focused"];

// Managing credit buttons: list/create at the collection, update/delete at one.
const BUTTONS_URL = "/byte/board/buttons";
const BUTTON_URL = (id) => `/byte/board/buttons/${id}`;

// A board item is one of four kinds, stamped by the server in `kind`:
//   * CHORE   — tick to complete, has state (ring, count, skips).
//   * TRIGGER — a routine, tapped to fire, no occurrence to settle.
//   * CREDIT  — a custom button that completes a chore crediting a chosen person.
//   * TASK    — a custom button that runs a Jil task (the Whisper controls).
// Triggers, credit buttons and task buttons are all stateless ACTION circles:
// one press, a flash, nothing to undo. Besides chores, a connected list's items
// (LIST) have state too: open, or checked off and waiting to leave.
function isTrigger(item) {
  return item && item.kind === "trigger";
}
function isCredit(item) {
  return item && item.kind === "credit";
}
function isTask(item) {
  return item && item.kind === "task";
}
function isAction(item) {
  return isTrigger(item) || isCredit(item) || isTask(item);
}
function isList(item) {
  return item && item.kind === "list";
}

// What a press looks like before the server has answered, and it is the same
// bargain /chores/today strikes: the tap is painted IMMEDIATELY from a locally
// predicted state, and nothing spins.
//
// Deliberately no in-flight spinner on the happy path. That page's own queue
// comment is explicit about why - items are "silent by default so a
// momentarily slow happy-path drain doesn't flash a 'pending' badge in the
// user's face" - and a board is pressed several times in a row while walking
// past, so a flicker on each one is worse than nothing. What says the touch
// landed is the ring moving under your finger.
//
// A press that hasn't gone through is the case that needs saying out loud, and
// it gets the same amber dot the chores page paints on a confirmed failure.
// Every press is written to this device's queue before it is sent (see
// board_queue.js), so one made with no connection is kept, shown as done, and
// sent with the time it was pressed once the board can reach the server.

// A thank-you from the pet is for a press it saw land. One that went out late,
// after the connection came back, lands quietly.
const CHEER_WITHIN_MS = 60 * 1000;

function newMutationId() {
  if (window.crypto?.randomUUID) return window.crypto.randomUUID();
  return `m-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`;
}

// What a waiting press does to its chore, laid over the server's last word so
// the screen shows it until the answer comes back. The answer replaces it.
const PREDICT = {
  // One more of today's target, capped. Nobody's colour until the server says
  // who it was: on a board that asks, it isn't whoever's signed in.
  complete: (c) => ({
    progress_count: Math.min(c.progress_count + 1, c.target_count),
    last_actor_username: null,
    last_actor_anonymous: false,
  }),
  undo: (c) => ({ progress_count: Math.max(c.progress_count - 1, 0) }),
  dismiss: () => ({ dismissed: true }),
  // A skip settles the WHOLE occurrence, so the circle reads as finished
  // rather than one-of-three done - the same clamp the serializer applies
  // server-side (see ChoreSerializer#progress_count).
  skip: (c) => ({ skipped_today: true, progress_count: c.target_count }),
  bring_back: (c, entry) => ({
    dismissed: false,
    skipped_today: false,
    progress_count: entry.was_skipped ? 0 : c.progress_count,
  }),
  // When it leaves is the server's to say; until then it stays.
  list_check: () => ({ checked: true, clears_at: null }),
  list_undo: () => ({ checked: false, clears_at: null }),
};

// Which cell a queued press belongs to.
const CELL_KIND = {
  complete: "chore", undo: "chore", dismiss: "chore", skip: "chore", bring_back: "chore",
  credit: "credit", trigger: "trigger", task: "task", list_check: "list", list_undo: "list",
};

// A board dark for longer than this gets a yawn when it comes back. Long
// enough that walking out of the room and back doesn't trigger one, short
// enough that the first person down in the morning gets it.
const WAKE_AFTER_MS = 5 * 60 * 60 * 1000;
const WAKE_KEY = "byte.board.lastSeen";

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

async function apiCall(url, method, body) {
  const options = {
    method,
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-CSRF-Token": csrfToken() },
  };
  if (body != null) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const res = await fetch(url, options);
  if (!res.ok) {
    const err = new Error(`http_${res.status}`);
    // The server's reason, where it gave one, for the field that sent it.
    err.body = await res.json().catch(() => null);
    throw err;
  }
  // A bare `head :ok` (a task press) is a success with nothing to read; parsing
  // it would throw and file the press as failed, to be run again later.
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// Which of the four states a cell is in, most settled first. Order matters:
// a chore can be both done and waved off (somebody did it after skipping it),
// and what it should read as is done.
function cellState(item) {
  // An action (trigger or credit button) has no occurrence to be done, skipped
  // or waved off - it is only ever "there to press", so it gets its own settled
  // state and none of the ring/corner machinery the four chore states drive.
  if (isAction(item)) return item.kind;
  if (isList(item)) return item.checked ? "done" : "open";
  if (item.progress_count >= item.target_count) return "done";
  if (item.skipped_today) return "skipped";
  if (item.dismissed) return "dismissed";
  return "open";
}

// Only what is being asked for today. `today_visible` is the same field
// /chores/today sorts on, so the board and the page agree about what the day
// holds without this knowing anything about recurrence. Dailies show either
// way, as they do in Today's Dailies section, and so do the chores pinned to
// this board.
//
// A dismissed or skipped chore is KEPT and greyed rather than dropped: it was
// on the board a moment ago and vanishing on a press reads as a mis-tap, and
// the grey circle is also the only way back to it.
function onBoard(items) {
  return items.filter((item) =>
    isAction(item) || isList(item) ? true : (item.today_visible || item.on_dailies || item.pinned) && !item.archived,
  );
}

// A whole number prints bare (2×), a fractional one keeps its places (1.5×).
// Mirrors the chores page so a multiplier reads the same on every surface.
function formatMultiplier(n) {
  if (n == null) return "";
  const f = Number(n);
  return f === Math.floor(f) ? String(Math.floor(f)) : String(f);
}

// "GO, checked items leave after 30 seconds": how a board's list is set, for
// the row that opens its dialog.
export function listSummary(config) {
  if (!config?.list_id) return "None";

  const clear = String(config.clear_after ?? 3600);
  let leave;
  if (clear === "end_of_day") leave = "at the end of the day";
  else if (Number(clear) === 0) leave = "straight away";
  else leave = `after ${humanizeSeconds(Number(clear))}`;
  return `${config.list_name || "List"}, checked items leave ${leave}`;
}

// A size as a tile sends it: a bare number is pixels.
function cssSize(value) {
  if (value == null || value === "") return null;
  return /^\d+(\.\d+)?$/.test(String(value).trim()) ? `${value}px` : String(value);
}

function setVar(el, name, value) {
  if (value) el.style.setProperty(name, value);
  else el.style.removeProperty(name);
}

// How a glyph string draws, the same rule as the server's Buddy::BoardIcon.
function iconKindFor(icon) {
  const v = String(icon || "").trim();
  if (!v) return "empty";
  if (/^(data:image\/|https?:\/\/)/.test(v)) return "image";
  if (v.startsWith("<svg")) return "svg";
  if (v.startsWith("ti-")) return "ti_icon";
  return "emoji";
}

// The icon, in whatever shape it arrived. Mirrors the four kinds the chore
// serializer resolves (`icon_kind`) rather than guessing from the string, so a
// glyph that happens to look like a path can't be read as one.
export function iconNode(chore) {
  // The BOX is what the container query measures, so the glyph always goes
  // inside one even when it is a single character - that is what makes an
  // emoji and an uploaded image render at the same visual size, and it is how
  // the chores page does it.
  const box = document.createElement("span");
  box.className = "byte-board-icon";

  if (chore.icon_kind === "image" || chore.icon_kind === "svg") {
    // SVG markup goes in as a picture of itself, so whatever it carries never
    // runs on the page.
    const markup = chore.icon_kind === "svg" && String(chore.icon).startsWith("<svg");
    const img = document.createElement("img");
    img.className = "byte-board-icon-img";
    img.src = markup ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(chore.icon)}` : chore.icon;
    img.alt = "";
    img.draggable = false;
    box.appendChild(img);
    return box;
  }
  if (chore.icon_kind === "ti_icon") {
    const i = document.createElement("i");
    i.className = `ti ${chore.icon}`;
    i.setAttribute("aria-hidden", "true");
    box.appendChild(i);
    return box;
  }
  // A chore with no icon still needs something to aim at, so it falls back to
  // the first letter of its name rather than being an empty disc.
  box.textContent = chore.icon || chore.short_name.slice(0, 1).toUpperCase();
  return box;
}

// How big this screen draws the circles, as a share of the default. Per screen
// rather than per board, so it lives on the device; keyed by the board so one
// tablet can show two boards at different sizes.
const SCALE_KEY = (id) => `byte.board.circleScale.${id}`;
const SCALE_MIN = 70;
const SCALE_MAX = 150;
const SCALE_STEP = 10;

export function initChoreBoard({
  root, app, conversationIdFn, sayText, flashFace, onTagsChanged, onItems, onChoreDreamsChanged,
  onDreamPaceChanged,
} = {}) {
  if (!root || !app) return null;

  const padEl = root.querySelector("[data-board-pad]");
  const emptyEl = root.querySelector("[data-board-empty]");
  const tagToggleEl = root.querySelector("[data-board-tag-toggle]");
  const tagPickerEl = root.querySelector("[data-board-tag-picker]");
  const tagListEl = root.querySelector("[data-board-tag-list]");

  // The credit-button manager, inside the group picker.
  const bbSectionEl = root.querySelector("[data-board-buttons-section]");
  const bbListEl = root.querySelector("[data-board-buttons-list]");
  const bbFormEl = root.querySelector("[data-board-button-form]");
  const bbDialogEl = root.querySelector("[data-bb-dialog]");
  const bbTitleEl = root.querySelector("[data-bb-title]");
  const bbNewEl = root.querySelector("[data-bb-new]");
  const bbCancelEl = root.querySelector("[data-bb-cancel]");
  const bbLabelEl = root.querySelector("[data-bb-label]");
  // The groups a new/edited button belongs to, comma-separated.
  const bbTagsEl = root.querySelector("[data-bb-tags]");
  // Completes: a button opening the board's chore picker; the hidden input
  // holds the chosen chore id.
  const bbChorePickEl = root.querySelector("[data-bb-chore-pick]");
  const bbChoreIdEl = root.querySelector("[data-bb-chore]");
  const bbCreditEl = root.querySelector("[data-bb-credit]");
  const bbColorEl = root.querySelector("[data-bb-color]");
  const bbIdEl = root.querySelector("[data-bb-id]");
  const bbSaveEl = root.querySelector("[data-bb-save]");
  const bbErrorEl = root.querySelector("[data-bb-error]");

  // Pinning chores to the board, inside the group picker. Owner-only.
  const pinsSectionEl = root.querySelector("[data-board-pins-section]");
  const pinsListEl = root.querySelector("[data-board-pins-list]");
  const pinAddEl = root.querySelector("[data-board-pin-add]");

  // The one chore picker both of those open: the Chores page's search over
  // each chore's own icon, in a modal over everything else.
  const chorePicker = initBoardChorePicker({
    dialog: root.querySelector("[data-board-chore-picker]"),
  });

  const cheerUrl = app.dataset.choreCheerUrl;
  // The board's own set endpoint, not /chores/sync: it answers with chores AND
  // triggers for the group, so a resync keeps the triggers on screen instead of
  // dropping them (the chores endpoint has never heard of them).
  const itemsUrl = app.dataset.boardItemsUrl;
  const tagUrl = app.dataset.boardTagUrl;
  const tagsUrl = app.dataset.boardTagsUrl;
  // Whose chores the board shows — owner-only, server-rendered into the picker.
  const membersUrl = app.dataset.boardMembersUrl;
  const memberBoxes = Array.from(root.querySelectorAll("[data-board-member]"));

  // The groups this board watches. Several, matched as "any": a chore, routine
  // or button in ANY of them appears here.
  let tags = [];
  try {
    tags = JSON.parse(app.dataset.boardTags || "[]");
  } catch (e) {
    tags = [];
  }
  const tagLabel = () => (tags.length ? tags.join(", ") : "Pick groups");
  // Running flash timers for trigger cells, by id, so a second press restarts
  // the "Done!" rather than letting the first one's timeout clear it early.
  const flashTimers = new Map();

  // What the server last said is on the board (`base`), and what the screen
  // shows (`items`): that, with every press still waiting laid over it. The
  // screen is only ever swapped for a newer answer, never emptied while one is
  // fetched, so a blip or a dropped connection leaves the circles standing.
  const boardId = String((conversationIdFn ? conversationIdFn() : null) ?? "");
  const KEPT_KEY = `byte.board.items.${boardId}`;
  let base = [];
  try {
    base = onBoard(JSON.parse(app.dataset.boardItems || "[]"));
  } catch (e) {
    base = [];
  }
  // A page that came out of the offline cache carries the set from when it was
  // cached; what this device last heard from the server may well be newer.
  const kept = readKept();
  if (kept && kept.at > (Date.parse(app.dataset.boardItemsAt || "") || 0)) base = onBoard(kept.items);

  function readKept() {
    try {
      const raw = JSON.parse(window.localStorage.getItem(KEPT_KEY) || "null");
      return raw && Array.isArray(raw.items) ? raw : null;
    } catch (e) {
      return null;
    }
  }

  function keep() {
    try {
      window.localStorage.setItem(KEPT_KEY, JSON.stringify({ at: Date.now(), items: base }));
    } catch (e) {}
  }

  const queue = createBoardQueue({
    key: `byte.board.queue.${boardId}`,
    send: sendEntry,
    onDone: landed,
    onChange: () => {
      items = withQueued(base);
      paint();
    },
  });

  function withQueued(from) {
    const out = from.slice();
    queue.entries().forEach((entry) => {
      const change = PREDICT[entry.kind];
      if (!change) return;
      const at = out.findIndex(
        (item) => (item.kind || "chore") === CELL_KIND[entry.kind] && String(item.id) === entry.item_id,
      );
      if (at >= 0) out[at] = { ...out[at], ...change(out[at], entry) };
    });
    return withoutCleared(out);
  }

  // A checked list item leaves once its time is up, without waiting on the
  // server to say so: a timer repaints at the next one due.
  let clearTimer = 0;
  function withoutCleared(list) {
    const now = Date.now();
    let next = Infinity;
    const kept = list.filter((item) => {
      if (!isList(item) || !item.checked || !item.clears_at) return true;
      const at = Date.parse(item.clears_at);
      if (at <= now) return false;
      next = Math.min(next, at);
      return true;
    });
    window.clearTimeout(clearTimer);
    if (next !== Infinity) {
      clearTimer = window.setTimeout(() => {
        items = withQueued(base);
        paint();
      }, Math.min(next - now + 50, 2 ** 31 - 1));
    }
    return kept;
  }

  let items = withQueued(base);

  // ---- task buttons that follow their tile ----
  //
  // A task button whose Jil task answers on a monitor tile wears what that tile
  // says right now, read the way the list pages' task buttons read it: `text`
  // is what's ON the button (drawn by setButtonText, so `[stack 🔔💤]` and
  // `[hicon name]` work), `color` its colour and `fontSize` the text's size.
  // On top of those a tile may send `icon` (an emoji, a `ti-` name, an image
  // URL or SVG markup), which is drawn in place of the text, `textColor`, and
  // `label` for the name under the disc, which is otherwise the button's own.
  // Only the board owner's broadcasts count.
  const tileFaces = new Map();
  const tileMonitors = new Map();
  const ownerId = boardOwnerId(app);

  // One listener per tile however many buttons wear it, all on the page's one
  // Monitor socket, and dropped once no button on the board answers there.
  function followTiles() {
    const wanted = new Set(items.filter(isTask).map((item) => item.monitor).filter(Boolean));
    tileMonitors.forEach((monitor, channel) => {
      if (wanted.has(channel)) return;
      monitor.unsubscribe();
      tileMonitors.delete(channel);
      tileFaces.delete(channel);
    });
    wanted.forEach((channel) => {
      if (tileMonitors.has(channel)) return;

      tileMonitors.set(channel, Monitor.subscribe(channel, {
        connected() {
          this.refresh();
        },
        received(data) {
          const face = data?.data;
          if (!face || !feedOwnerMatches(data.owner_id, ownerId)) return;
          const { icon, text, label, color, fontSize, textColor } = face;
          if ([icon, text, label, color, fontSize, textColor].every((v) => v == null)) return;

          tileFaces.set(channel, {
            icon, text: text == null ? null : String(text), label, color, fontSize: cssSize(fontSize), textColor,
          });
          paint();
        },
      }));
    });
  }

  // Repaints only when the face changed, so a broadcast that says the same
  // thing again leaves the disc alone.
  function paintTileFace(cell, item) {
    const face = item.monitor ? tileFaces.get(item.monitor) : null;
    const text = face?.icon ? null : face?.text;
    const icon = face?.icon || item.icon;
    const label = face?.label || item.short_name;
    const color = face?.color || item.color;
    const key = [icon, text, label, color, face?.fontSize, face?.textColor].map((v) => v || "").join("|");
    if (cell.dataset.face === key) return;

    cell.dataset.face = key;
    setVar(cell, "--actor-color", color);
    setVar(cell, "--board-face-color", face?.textColor);
    let glyph;
    if (text) {
      glyph = document.createElement("span");
      glyph.className = "byte-board-icon byte-board-face-text";
      // A glyph (a stack or a household icon counting as one) draws at icon
      // size; words wrap smaller.
      const bare = text.replace(/\[(stack|hicon) [^\]]*\]/gi, "*");
      glyph.dataset.words = String(splitGraphemes(bare.trim()).length > 2);
      if (face.fontSize) glyph.style.fontSize = face.fontSize;
      setButtonText(glyph, text);
    } else {
      const kind = face?.icon ? iconKindFor(face.icon) : item.icon_kind;
      glyph = iconNode({ icon, icon_kind: kind, short_name: label });
    }
    cell.querySelector(".byte-board-icon")?.replaceWith(glyph);
    const title = cell.querySelector(".byte-board-title");
    if (title) title.textContent = label;
    cell.querySelector(".byte-board-circle")?.setAttribute("aria-label", `Start: ${label}`);
  }

  // ---- painting ----

  function paintEmpty() {
    if (!emptyEl) return;

    // Two different kinds of nothing. No groups is a screen nobody has pointed
    // at a group yet, and the fix is a setting; empty groups means the day is
    // actually clear, which is the good one.
    if (!tags.length) {
      emptyEl.textContent =
        "This screen isn't looking after anything yet — pick a group below.";
    } else if (items.length === 0) {
      emptyEl.textContent = `Nothing left in ${tags.join(", ")} today.`;
    }
    emptyEl.hidden = items.length > 0;
  }

  // Whether a press on this item is on its way, or waiting on a connection or
  // a retry. Shared by every kind, so a trigger's dim-while-sending reads the
  // same as a chore's. `pending` is worked out once per paint.
  let pending = new Map();
  function pendingNow() {
    const map = new Map();
    queue.entries().forEach((entry) => {
      const key = `${CELL_KIND[entry.kind]}:${entry.item_id}`;
      const was = map.get(key) || { sending: false, loud: false };
      map.set(key, { sending: was.sending || !entry.loud, loud: was.loud || !!entry.loud });
    });
    return map;
  }
  function markPending(cell, item) {
    const state = pending.get(`${item.kind || "chore"}:${item.id}`);
    cell.dataset.sending = state?.sending ? "true" : "false";
    cell.dataset.syncPending = state?.loud ? "true" : "false";
  }

  function paintCell(cell, chore) {
    cell.dataset.state = cellState(chore);
    cell.dataset.boardCell = String(chore.id);

    // An action (trigger / credit button) is stateless: no ring, no count, no
    // skip/undo corners to show or hide. All a repaint does for one is keep its
    // sending/failed dot honest.
    if (isAction(chore)) {
      markPending(cell, chore);
      if (isTask(chore)) paintTileFace(cell, chore);
      return;
    }
    if (isList(chore)) {
      cell.dataset.priority = chore.priority || "normal";
      const ring = cell.querySelector("[data-board-ring]");
      if (ring) {
        ring.style.strokeDashoffset = chore.checked ? "0" : "100";
        ring.style.opacity = chore.checked ? "1" : "0";
      }
      const undo = cell.querySelector("[data-board-list-undo]");
      if (undo) undo.hidden = !chore.checked;
      markPending(cell, chore);
      return;
    }

    // Who the done disc belongs to. Same `--actor-color` the chores page keys
    // its finished state off, carried here on data-actor so a chore I finished
    // reads in my colour rather than the board's flat default grey. Anonymous
    // completions stay colourless (the grey the chores page uses); an unfinished
    // or never-completed chore clears both so it falls back to the default.
    if (chore.last_actor_anonymous) {
      cell.dataset.actorAnonymous = "true";
      delete cell.dataset.actor;
    } else if (chore.last_actor_username) {
      cell.dataset.actor = chore.last_actor_username;
      delete cell.dataset.actorAnonymous;
    } else {
      delete cell.dataset.actor;
      delete cell.dataset.actorAnonymous;
    }

    // Same arithmetic the chores page's applyProgressRing uses: a fixed
    // dasharray of 100 with the OFFSET carrying the progress, rather than a
    // two-value dasharray. It has to match, because `pathLength=100` plus
    // dashoffset is what lets a 2-of-5 chore show exactly 40% of the same
    // thick ring a finished one shows.
    //
    // Faded out entirely at zero: `stroke-linecap: round` leaves a dot at the
    // start of the path otherwise, which reads as one tap already in.
    const ring = cell.querySelector("[data-board-ring]");
    if (ring) {
      const done = Math.min(chore.progress_count, chore.target_count);
      const ratio = chore.target_count > 0 ? done / chore.target_count : 0;
      ring.style.strokeDashoffset = String(100 * (1 - ratio));
      ring.style.opacity = ratio > 0 ? "1" : "0";
    }

    const count = cell.querySelector("[data-board-count]");
    if (count) {
      // Only on a chore asked for more than once a day. On a single-press one
      // the ring already says everything "0/1" would.
      const show = chore.target_count > 1;
      count.hidden = !show;
      if (show)
        count.textContent = `${chore.progress_count}/${chore.target_count}`;
    }

    // The pay-extra pills, shown only when they're earning something: a hot
    // multiplier is present only on a pick, a streak forecast is 1 until a
    // bonus applies. Same thresholds the chores page draws its badges on.
    const hot = cell.querySelector("[data-board-hot]");
    if (hot) {
      const show = chore.hot_multiplier != null;
      hot.hidden = !show;
      if (show) {
        hot.textContent = `${formatMultiplier(chore.hot_multiplier)}×`;
        hot.classList.toggle("rare", Number(chore.hot_multiplier) >= 5);
      }
    }
    const streak = cell.querySelector("[data-board-streak]");
    if (streak) {
      const show = chore.streak_multiplier != null && chore.streak_multiplier > 1;
      streak.hidden = !show;
      if (show) streak.textContent = `${formatMultiplier(chore.streak_multiplier)}×`;
    }

    // There is nothing to skip on a chore that is already done or already put
    // away, so the corners carry whichever control the state can actually act
    // on - the two skips while it is still asking, Undo once it isn't, and
    // nothing at all once it is finished.
    const away = chore.dismissed || chore.skipped_today;
    const state = cell.dataset.state;
    const hide = (sel, yes) => {
      const el = cell.querySelector(sel);
      if (el) el.hidden = yes;
    };
    hide("[data-board-skip-day]", state !== "open");
    hide("[data-board-skip-cycle]", state !== "open");
    hide("[data-board-undo]", !away || state === "done");

    // Derived here rather than left on the node, so it follows the queue
    // rather than whatever was true when the cell was built.
    markPending(cell, chore);
  }

  function buildCell(item) {
    if (isList(item)) return buildListCell(item);
    return isAction(item) ? buildActionCell(item) : buildChoreCell(item);
  }

  function ringSvg() {
    const ring = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    ring.setAttribute("class", "byte-board-ring");
    ring.setAttribute("viewBox", "0 0 100 100");
    ring.setAttribute("aria-hidden", "true");
    const arc = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    arc.setAttribute("cx", "50");
    arc.setAttribute("cy", "50");
    arc.setAttribute("r", "48");
    arc.setAttribute("pathLength", "100");
    arc.setAttribute("data-board-ring", "");
    ring.appendChild(arc);
    return ring;
  }

  // A list item: pressed to check it off, when its ring fills; Undo puts it
  // back while it's still here. The name goes on the disc unless it leads with
  // an emoji, which is then the picture and the name sits underneath.
  function buildListCell(item) {
    const cell = document.createElement("div");
    cell.className = "byte-board-cell";
    cell.dataset.kind = "list";
    cell.setAttribute("role", "listitem");

    const disc = document.createElement("div");
    disc.className = "byte-board-disc";

    const press = document.createElement("button");
    press.type = "button";
    press.className = "byte-board-circle";
    press.dataset.boardComplete = String(item.id);
    press.dataset.boardKind = "list";
    press.setAttribute("aria-label", `Check off: ${item.short_name}`);

    let face;
    if (item.icon) {
      face = iconNode(item);
    } else {
      face = document.createElement("span");
      face.className = "byte-board-icon byte-board-face-text";
      face.dataset.words = String(splitGraphemes(item.short_name.trim()).length > 2);
      face.textContent = item.short_name;
    }
    press.append(ringSvg(), face);

    const undo = document.createElement("button");
    undo.type = "button";
    undo.className = "byte-board-undo";
    undo.dataset.boardListUndo = String(item.id);
    undo.setAttribute("aria-label", `Put ${item.short_name} back on the list`);
    undo.title = "Put it back";
    undo.textContent = "Undo";
    undo.hidden = true;

    const title = document.createElement("span");
    title.className = "byte-board-title";
    title.textContent = item.icon ? item.short_name : "";

    disc.append(press, undo);
    cell.append(disc, title);
    paintCell(cell, item);
    return cell;
  }

  // An action circle (trigger or credit button): the icon to aim at and a title,
  // and nothing else. No ring (no progress), no count (nothing to count), no
  // skip/cycle/undo corners (no occurrence to let go of). A press fires it once;
  // what says the tap landed is a brief flash over the disc — because, unlike a
  // chore, there is no state change to see. A credit button carries its own
  // colour; a trigger falls back to the stylesheet's default.
  function buildActionCell(item) {
    const cell = document.createElement("div");
    cell.className = "byte-board-cell";
    cell.dataset.kind = item.kind;
    cell.setAttribute("role", "listitem");
    // A custom colour overrides the per-kind default, and drives both the disc
    // tint and the flash (both read --actor-color).
    if (item.color) cell.style.setProperty("--actor-color", item.color);

    const disc = document.createElement("div");
    disc.className = "byte-board-disc";

    const press = document.createElement("button");
    press.type = "button";
    press.className = "byte-board-circle";
    // The same hook a chore circle carries, so the one pad listener finds all
    // three; the kind rides on the button so the handler routes the press
    // without having to walk up to the cell.
    press.dataset.boardComplete = String(item.id);
    press.dataset.boardKind = item.kind;
    press.setAttribute(
      "aria-label",
      `${isCredit(item) ? "Mark done" : "Start"}: ${item.short_name}`,
    );
    press.appendChild(iconNode(item));

    const flash = document.createElement("span");
    flash.className = "byte-board-flash";
    flash.dataset.boardFlash = "";
    flash.textContent = "Done!";
    flash.hidden = true;

    disc.append(press, flash);

    const title = document.createElement("span");
    title.className = "byte-board-title";
    title.textContent = item.short_name;

    cell.append(disc, title);
    paintCell(cell, item);
    return cell;
  }

  function buildChoreCell(chore) {
    const cell = document.createElement("div");
    cell.className = "byte-board-cell";
    cell.setAttribute("role", "listitem");

    // The disc and its corner controls share a square wrapper, so the pills
    // can be positioned against the DISC's own bottom corners. Anchored to the
    // cell instead they would land next to the title underneath it, since the
    // cell is as tall as the disc plus two lines of label.
    const disc = document.createElement("div");
    disc.className = "byte-board-disc";

    const press = document.createElement("button");
    press.type = "button";
    press.className = "byte-board-circle";
    press.dataset.boardComplete = String(chore.id);
    press.dataset.boardKind = "chore";
    press.setAttribute("aria-label", `Done: ${chore.short_name}`);

    const ring = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    ring.setAttribute("class", "byte-board-ring");
    ring.setAttribute("viewBox", "0 0 100 100");
    ring.setAttribute("aria-hidden", "true");
    const arc = document.createElementNS(
      "http://www.w3.org/2000/svg",
      "circle",
    );
    arc.setAttribute("cx", "50");
    arc.setAttribute("cy", "50");
    // r=48 with a 4-wide stroke puts the ring on the disc's own edge, same as
    // the chores page. The SVG is `overflow: visible` so the half of the
    // stroke outside the radius isn't clipped off.
    arc.setAttribute("r", "48");
    arc.setAttribute("pathLength", "100");
    arc.setAttribute("data-board-ring", "");
    ring.appendChild(arc);

    const count = document.createElement("span");
    count.className = "byte-board-count";
    count.dataset.boardCount = "";
    count.hidden = true;

    press.append(ring, iconNode(chore), count);

    const title = document.createElement("span");
    title.className = "byte-board-title";
    title.textContent = chore.short_name;

    // Both skips, one press each, in the two bottom corners of the disc.
    //
    // No menu behind them. A board gets walked up to with one hand full, and
    // the two things you ever want are "not today" and "done with this one" -
    // routed through a sheet, each of those cost a press to open, a read, a
    // press to choose and a press to dismiss. They are also deliberately
    // VISIBLE rather than a long-press: a long-press has to be known about to
    // be found, and these are the controls that stop the board nagging.
    const skip = document.createElement("button");
    skip.type = "button";
    skip.className = "byte-board-skip";
    skip.dataset.boardSkipDay = String(chore.id);
    skip.setAttribute("aria-label", `Skip ${chore.short_name} for today`);
    skip.title = "Not today — back tomorrow";
    skip.textContent = "Skip";

    const cycle = document.createElement("button");
    cycle.type = "button";
    cycle.className = "byte-board-cycle";
    cycle.dataset.boardSkipCycle = String(chore.id);
    cycle.setAttribute("aria-label", `Skip this cycle of ${chore.short_name}`);
    cycle.title = "Skip this cycle — back when it's next due";
    cycle.textContent = "Cycle";

    // The way back from a mis-press. It replaces the pair rather than sitting
    // beside them, because there is nothing to skip on a chore already put
    // away and three controls do not fit in two corners.
    const undo = document.createElement("button");
    undo.type = "button";
    undo.className = "byte-board-undo";
    undo.dataset.boardUndo = String(chore.id);
    undo.setAttribute(
      "aria-label",
      `Put ${chore.short_name} back on the board`,
    );
    undo.title = "Put it back";
    undo.textContent = "Undo";

    // Multiplier pills, in the same corners the chores page uses: a hot pick's
    // boost top-left, the streak forecast top-right. Built hidden and filled in
    // paintCell so an in-place repaint keeps their DOM identity.
    const hotBadge = document.createElement("span");
    hotBadge.className = "byte-board-hot";
    hotBadge.dataset.boardHot = "";
    hotBadge.hidden = true;

    const streakBadge = document.createElement("span");
    streakBadge.className = "byte-board-streak";
    streakBadge.dataset.boardStreak = "";
    streakBadge.hidden = true;

    disc.append(press, skip, cycle, undo, hotBadge, streakBadge);
    cell.append(disc, title);
    paintCell(cell, chore);
    return cell;
  }

  // What a cell was BUILT from - its icon, title and colour - as opposed to the
  // state paintCell keeps up to date. A change here rebuilds that one cell.
  function cellBuiltFrom(item) {
    return [item.icon, item.icon_kind, item.short_name, item.color].map((v) => v ?? "").join("|");
  }

  // Each cell is kept, patched in place, and only moved, added or removed when
  // the set itself changes - never the whole pad dropped and rebuilt. A tablet
  // left on the counter repaints on every household tap, and swapping every
  // node kills the press animation mid-flourish, scrolls the pad back to the
  // top and flashes an empty board.
  function paint() {
    if (!padEl) return;

    pending = pendingNow();
    // The kinds come from different tables and can share an id, so the cell
    // key carries the kind too.
    const key = (item) => `${item.kind || "chore"}:${item.id}`;
    const existing = new Map(Array.from(padEl.children).map((el) => [el.dataset.boardKey, el]));
    let prev = null;
    items.forEach((item) => {
      const k = key(item);
      let cell = existing.get(k);
      existing.delete(k);
      if (cell && cell.dataset.boardBuilt !== cellBuiltFrom(item)) {
        const fresh = buildCell(item);
        cell.replaceWith(fresh);
        cell = fresh;
      } else if (cell) {
        paintCell(cell, item);
      } else {
        cell = buildCell(item);
      }
      cell.dataset.boardKey = k;
      cell.dataset.boardBuilt = cellBuiltFrom(item);
      const slot = prev ? prev.nextSibling : padEl.firstChild;
      if (cell !== slot) padEl.insertBefore(cell, slot);
      prev = cell;
    });
    existing.forEach((el) => el.remove());

    paintEmpty();
    followTiles();
    onItems?.(items);
  }

  // By id AND kind: the three kinds come from different tables and can collide
  // on id, so a bare id lookup would hand a press on one to another. `kind` is
  // "chore" | "trigger" | "credit" (chores are stamped "chore" server-side).
  function find(id, kind) {
    return items.find(
      (item) =>
        String(item.id) === String(id) &&
        (kind === undefined || (item.kind || "chore") === kind),
    );
  }

  // ---- the server's answer ----

  // Fold one chore's new state back in. The endpoints all answer with the same
  // serialized chore the page was built from, so a press costs one request and
  // not a re-sync of the whole board.
  function absorb(payload) {
    const fresh = payload?.chore || payload;
    if (!fresh || fresh.id == null) return;

    // A completion endpoint only ever answers with a chore, so fold it back into
    // the chore sharing its id - never an action that happens to collide on one.
    const at = base.findIndex(
      (item) => (item.kind || "chore") === "chore" && item.id === fresh.id,
    );
    if (at >= 0) {
      base[at] = { ...fresh, kind: "chore" };
      keep();
    }
    items = withQueued(base);
    paint();

    // An `after_chore` follower coming due is a chore ARRIVING on the board,
    // which this can't fold in - the set changed rather than one row in it.
    if (Array.isArray(payload?.chores) && payload.chores.length > 0) resyncSoon();
  }

  // A list press answers with the item as it now stands, which says when a
  // checked one leaves.
  function absorbListItem(fresh) {
    const at = base.findIndex((item) => isList(item) && String(item.id) === String(fresh.id));
    if (at >= 0) {
      base[at] = fresh;
      keep();
    }
    items = withQueued(base);
    paint();
  }

  // Counts presses as they land, so a fetch that set out before one did can
  // tell its answer is already behind and ask again.
  let landedCount = 0;

  // Re-pull the whole board - chores AND triggers of the group - from the
  // board's own endpoint. It already filters to the thread's tag server-side
  // and stays correct across the 4am rollover (it leans on /chores/today's own
  // serializer), so there is nothing to filter here and triggers come back on
  // the set instead of being dropped. What's on screen stays until the answer
  // is in; a failed fetch leaves it, since a wall tablet that blanks itself on
  // a blip is worse than a stale one.
  async function resync() {
    if (!itemsUrl) return;

    const conversationId = conversationIdFn ? conversationIdFn() : null;
    const url = conversationId
      ? `${itemsUrl}?conversation_id=${encodeURIComponent(conversationId)}`
      : itemsUrl;

    const startedAt = landedCount;
    try {
      const data = await apiCall(url, "GET");
      if (!Array.isArray(data?.items)) return;
      if (landedCount !== startedAt) return resyncSoon();

      base = onBoard(data.items);
      keep();
      items = withQueued(base);
      paint();
    } catch (e) {}
  }

  let resyncTimer = 0;
  function resyncSoon() {
    window.clearTimeout(resyncTimer);
    resyncTimer = window.setTimeout(resync, 250);
  }

  // ---- sending presses ----

  async function refreshCsrf() {
    if (!app.dataset.csrfUrl) return false;
    try {
      const res = await fetch(app.dataset.csrfUrl, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      const token = res.ok ? (await res.json())?.token : null;
      if (!token) return false;
      document.querySelector('meta[name="csrf-token"]')?.setAttribute("content", token);
      return true;
    } catch (e) {
      return false;
    }
  }

  function sendOnce(req) {
    return fetch(req.url, {
      method: req.method,
      credentials: "same-origin",
      redirect: "manual",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken(),
      },
      body: req.body ? JSON.stringify(req.body) : undefined,
    });
  }

  // One queued press: its requests in order. Signed out, rate limited or the
  // server struggling keeps it for later; anything else the server turns down
  // (the chore archived, nothing left to undo) is dropped, and the resync that
  // follows shows the board as it really is. A stale CSRF token is renewed once.
  async function sendEntry(entry) {
    let data = null;
    for (const req of entry.requests) {
      let res = await sendOnce(req);
      if (res.status === 422 && (await refreshCsrf())) res = await sendOnce(req);
      if (res.ok) {
        const text = await res.text();
        data = text ? JSON.parse(text) : null;
        continue;
      }
      const later =
        res.type === "opaqueredirect" || res.status === 0 || res.status === 401 ||
        res.status === 403 || res.status === 429 || res.status >= 500;
      return { ok: false, retry: later };
    }
    return { ok: true, data };
  }

  // Mutation ids of completions that reached the server, newest last, so an
  // undo can name exactly the one it takes back.
  const landedCompletes = new Map();

  // A queued press is finished: landed with the server's answer, or refused /
  // expired. The receipt (a cheer, a "Done!") only for one pressed just now.
  function landed(entry, data, ok) {
    landedCount += 1;
    if (ok && entry.kind === "complete" && entry.mutation_id) {
      const list = landedCompletes.get(entry.item_id) || [];
      list.push(entry.mutation_id);
      landedCompletes.set(entry.item_id, list);
    }
    if (ok && data?.item && CELL_KIND[entry.kind] === "list") absorbListItem(data.item);
    else if (ok && data && (data.chore || data.id != null)) absorb(data);
    // A skip or bring-back answers with something other than the chore, and a
    // refused press leaves the screen showing what it predicted.
    if (!ok || entry.kind === "skip" || entry.kind === "bring_back") resyncSoon();
    if (!ok || Date.now() - Date.parse(entry.queued_at) > CHEER_WITHIN_MS) return;

    if (entry.kind === "complete") cheer(find(entry.item_id, "chore"), "chore_done");
    if (CELL_KIND[entry.kind] !== "chore") flashCell(entry.item_id, entry.kind);
  }

  async function cheer(chore, kind) {
    const conversationId = conversationIdFn ? conversationIdFn() : null;
    if (!cheerUrl || !conversationId) return;

    try {
      const line = await apiCall(cheerUrl, "POST", {
        conversation_id: conversationId,
        chore_id: chore ? chore.id : null,
        kind,
      });
      // The FACE is not set here. `chore_cheer` wears it server-side and the
      // broadcast repaints the pet, which is the one writer of that column -
      // the same path a `[[mood:]]` on a real reply takes.
      if (line?.say) sayText?.(line.say);
    } catch (e) {
      // The chore is logged either way. A missing well-done is a missing
      // well-done; it is not worth telling anybody the tap failed over.
    }
  }

  // ---- pressing things ----
  //
  // Every press is queued with the request(s) it makes and what it does to the
  // screen meanwhile; the queue sends it now, or as soon as it can.

  const boardParam = () => (conversationIdFn ? conversationIdFn() : null);

  // Resolves once the press has been tried.
  function enqueue(kind, id, requests, extra = {}) {
    return queue.enqueue({ kind, item_id: String(id), requests, ...extra });
  }

  function waiting(kinds, id) {
    return queue.entries().filter((e) => kinds.includes(e.kind) && e.item_id === String(id));
  }

  function complete(id) {
    if (!find(id, "chore")) return;

    // The time it was pressed and an id the server dedupes on, so a press sent
    // late - or twice, when its answer was lost - is credited once, then.
    const mid = newMutationId();
    return enqueue("complete", id, [{
      url: COMPLETE_URL(id),
      method: "POST",
      // The board goes along so the server can tell a press on a board that
      // asks who did it from one that credits whoever's signed in.
      body: { client_completed_at: new Date().toISOString(), client_mutation_id: mid, board_id: boardParam() },
    }], { mutation_id: mid });
  }

  // Fire a trigger: run its routine, then flash the "Done!" over the disc. No
  // prediction (nothing to move), and no `cheer` - the flash is the receipt, and
  // a "nice work" over a thing you set off rather than finished reads wrong.
  function fire(id) {
    if (!find(id, "trigger")) return;
    return enqueue("trigger", id, [{ url: RUN_URL(id), method: "POST", body: { conversation_id: boardParam() } }]);
  }

  // Credit a chore on someone's behalf: complete it crediting the button's
  // chosen member, then flash and fold the fresh chore back in so its own circle
  // (if it's on this board too) flips to done. The board it was pressed on
  // decides what a "whoever did it" button does: on one that asks, the owner is
  // asked who it was.
  function creditPress(id) {
    if (!find(id, "credit")) return;
    return enqueue("credit", id, [{
      url: PRESS_URL(id),
      method: "POST",
      body: { board_id: boardParam(), client_completed_at: new Date().toISOString(), client_mutation_id: newMutationId() },
    }]);
  }

  // Run a task button's Jil task, then flash "Done!" over the disc. The task's
  // own effect comes back through the board's live feeds (its tile, rings, a
  // sound, an alert).
  function taskPress(id) {
    if (!find(id, "task")) return;
    flashFace?.(TASK_FACES[Math.floor(Math.random() * TASK_FACES.length)]);
    return enqueue("task", id, [{ url: TASK_PRESS_URL(id), method: "POST", body: { conversation_id: boardParam() } }]);
  }

  // The "Done!" receipt over an action disc. Scoped by board-key so it lands on
  // the right cell and not another kind's item sharing its id.
  function flashCell(id, kind) {
    const cell = padEl?.querySelector(`[data-board-key="${kind}:${CSS.escape(String(id))}"]`);
    const el = cell?.querySelector("[data-board-flash]");
    if (!el) return;

    el.hidden = false;
    el.dataset.on = "true";
    window.clearTimeout(flashTimers.get(String(id)));
    flashTimers.set(
      String(id),
      window.setTimeout(() => {
        el.dataset.on = "false";
        el.hidden = true;
      }, 1600),
    );
  }

  // Check a list item off, as of now; pressed again while it's checked, nothing
  // - Undo is the way back. Undoing one still waiting to be sent just takes it
  // back off the queue.
  function listCheck(id) {
    const item = find(id, "list");
    if (!item || item.checked) return;
    return enqueue("list_check", id, [{
      url: LIST_CHECK_URL(id),
      method: "POST",
      body: { conversation_id: boardParam(), client_checked_at: new Date().toISOString() },
    }]);
  }

  function listUndo(id) {
    const queued = waiting(["list_check"], id);
    if (queued.length) return queued.forEach((e) => queue.remove(e.qid));
    if (!find(id, "list")?.checked) return;
    return enqueue("list_undo", id, [{
      url: LIST_CHECK_URL(id),
      method: "DELETE",
      body: { conversation_id: boardParam() },
    }]);
  }

  function dismiss(id, span) {
    if (!find(id, "chore")) return;
    return enqueue("dismiss", id, [{ url: DISMISS_URL(id), method: "POST", body: { span } }]);
  }

  function skipCycle(id) {
    if (!find(id, "chore")) return;
    return enqueue("skip", id, [{
      url: SKIP_URL(id),
      method: "POST",
      body: { client_completed_at: new Date().toISOString() },
    }]);
  }

  // Take the last completion back off - the hold gesture's undo for a chore
  // that's done (or part-done). A press still waiting to be sent is simply taken
  // back off the queue; otherwise the same DELETE the chores page's long-press
  // sends, naming the completion it takes back when this board sent it.
  function undoComplete(id) {
    if (!find(id, "chore")) return;

    const last = waiting(["complete"], id).pop();
    if (last && queue.remove(last.qid)) return;

    const target = last?.mutation_id || landedCompletes.get(String(id))?.pop() || null;
    return enqueue("undo", id, [{
      url: COMPLETE_URL(id),
      method: "DELETE",
      body: { board_id: boardParam(), target_client_mutation_id: target },
    }]);
  }

  // Put a skipped or waved-off chore back. One still waiting to be sent is just
  // taken back; otherwise whichever put it away is reversed - "bring it back" is
  // the same intent either way, and the person pressing it is not thinking
  // about which mechanism was used.
  function bringBack(id) {
    waiting(["dismiss", "skip"], id).forEach((e) => queue.remove(e.qid));
    const chore = find(id, "chore");
    if (!chore || !(chore.dismissed || chore.skipped_today)) return;

    const requests = [];
    if (chore.dismissed) requests.push({ url: DISMISS_URL(id), method: "DELETE" });
    if (chore.skipped_today) requests.push({ url: SKIP_URL(id), method: "DELETE" });
    return enqueue("bring_back", id, requests, { was_skipped: !!chore.skipped_today });
  }

  // The panel's border says where things stand: a brief flash when a save
  // lands, and orange while something typed is waiting on its save button (a
  // lit button is an unsaved change) or a credit button is half filled in.
  let savedTimer = 0;
  function flashSaved() {
    if (!tagPickerEl) return;
    tagPickerEl.dataset.saved = "true";
    clearTimeout(savedTimer);
    savedTimer = window.setTimeout(() => { tagPickerEl.dataset.saved = "false"; }, 1200);
  }

  // The credit-button dialog carries its own: orange once anything in it is
  // changed, until it's saved or put away.
  let bbDirty = false;
  function paintDirty() {
    if (bbDialogEl) bbDialogEl.dataset.dirty = String(bbDirty);
    if (!tagPickerEl) return;
    const unsaved = [...tagPickerEl.querySelectorAll("[data-board-rename-save], [data-board-hidden-save]")]
      .some((btn) => !btn.disabled);
    tagPickerEl.dataset.dirty = String(unsaved);
  }

  // ---- which group ----

  async function paintTagPicker() {
    if (!tagListEl || !tagsUrl) return;

    try {
      const data = await apiCall(tagsUrl, "GET");
      tagListEl.innerHTML = "";
      Array(data?.tags || [])
        .flat()
        .forEach((name) => {
          const btn = document.createElement("button");
          btn.type = "button";
          btn.className = "byte-board-tag-option";
          btn.dataset.boardPickTag = name;
          btn.textContent = name;
          if (tags.some((t) => t.toLowerCase() === name.toLowerCase()))
            btn.dataset.current = "true";
          tagListEl.appendChild(btn);
        });
      if (!tagListEl.children.length) {
        const none = document.createElement("p");
        none.className = "byte-board-tag-empty";
        none.textContent =
          "Nothing's grouped yet — tag a chore on the chores page, or a routine in the Routines panel.";
        tagListEl.appendChild(none);
      }
    } catch (e) {
      // Leave the list as it was; the board itself is unaffected.
    }
  }

  // Add or remove one group from the set this board watches. The picker stays
  // open so several can be toggled in a row — each toggle is its own save, so
  // the board reflects the full set the moment it comes back.
  async function toggleTag(name) {
    const conversationId = conversationIdFn ? conversationIdFn() : null;
    if (!tagUrl || !conversationId) return;

    const has = tags.some((t) => t.toLowerCase() === name.toLowerCase());
    const next = has
      ? tags.filter((t) => t.toLowerCase() !== name.toLowerCase())
      : tags.concat(name);

    try {
      const data = await apiCall(tagUrl, "PATCH", {
        conversation_id: conversationId,
        tags: next,
      });
      applyTags(Array.isArray(data?.chore_tags) ? data.chore_tags : [], { broadcast: true });
      flashSaved();
    } catch (e) {
      // The screen keeps looking after whatever it was looking after.
    }
  }

  // Everything a change of watched groups has to repaint, from either source:
  // this device's own toggle (above) or another device's change arriving as a
  // conversation broadcast (setTags). The dataset is the shared source the
  // rings, sounds and alert scopes read from, so it is kept in step here —
  // leaving it stale was why the Whisper feeds didn't follow a group change.
  function applyTags(next, { broadcast } = {}) {
    tags = Array.isArray(next) ? next : [];
    try { app.dataset.boardTags = JSON.stringify(tags); } catch (e) {}
    // The timers placed on this board follow its groups.
    app.dispatchEvent(new CustomEvent("board:placement-changed"));
    if (tagToggleEl) tagToggleEl.textContent = tagLabel();
    // The circles stay until the new set is in, rather than the board going
    // blank while it's fetched.
    resync();
    // The watched groups just changed, so which buttons the picker shows and the
    // chore a new one files against have too - re-mark and repaint rather than
    // leaving the old set showing.
    paintTagPicker();
    resetButtonForm();
    paintButtons();
    taskButtons.reset();
    taskButtons.refresh();
    if (broadcast) onTagsChanged?.(tags);
  }

  // ---- pinned chores ----
  //
  // The chores this board shows whatever its groups and whatever the schedule.
  // The ids live on the app element (server-rendered, and rewritten by a
  // broadcast), the names come from the same chore list the credit buttons
  // search.

  let pinOptions = [];

  function pinnedIds() {
    try {
      const ids = JSON.parse(app.dataset.boardPins || "[]");
      return Array.isArray(ids) ? ids.map(Number) : [];
    } catch (e) {
      return [];
    }
  }

  async function savePins(ids) {
    if (!pinsSectionEl) return;
    const conversationId = conversationIdFn ? conversationIdFn() : null;
    try {
      const data = await apiCall(pinsSectionEl.dataset.url, "POST", {
        conversation_id: conversationId, chore_ids: ids,
      });
      app.dataset.boardPins = JSON.stringify(data?.chore_ids || []);
      paintPins();
      resync();
      flashSaved();
    } catch (e) {
      // Nothing stored, so the list stays as it was.
    }
  }

  function paintPinList() {
    if (!pinsListEl) return;
    pinsListEl.innerHTML = "";
    const ids = pinnedIds();
    if (ids.length === 0) {
      const none = document.createElement("p");
      none.className = "byte-board-tag-empty";
      none.textContent = "Nothing pinned yet.";
      pinsListEl.appendChild(none);
      return;
    }
    // Each pin as the chore it is - its icon and name - from the picker's list,
    // or the board's own items before that has loaded.
    const known = new Map(pinOptions.map((c) => [Number(c.id), c]));
    items.forEach((item) => {
      if (item.pinned && !known.has(Number(item.id))) known.set(Number(item.id), item);
    });
    ids.forEach((id) => {
      const chore = known.get(id);
      const row = document.createElement("div");
      row.className = "byte-board-button-row";
      row.dataset.pinRow = String(id);
      const label = document.createElement("span");
      label.className = "byte-board-button-edit byte-board-pin-name";
      if (chore?.icon_kind) label.appendChild(iconNode(chore));
      label.append(document.createTextNode(chore?.name || "A chore you can't see any more"));
      const del = document.createElement("button");
      del.type = "button";
      del.className = "byte-board-button-del";
      del.setAttribute("aria-label", `Unpin ${chore?.name || "this chore"}`);
      del.textContent = "×";
      del.addEventListener("click", () => savePins(pinnedIds().filter((p) => p !== id)));
      row.append(rowHandle(), label, del);
      pinsListEl.appendChild(row);
    });
  }

  // Pins lead the board in the order they're listed, so dragging one moves it.
  if (pinsListEl) {
    sortableRows(pinsListEl, "[data-pin-row]", (rows) => savePins(rows.map((row) => Number(row.dataset.pinRow))));
  }

  async function paintPins() {
    if (!pinsSectionEl) return;
    paintPinList();
    if (pinOptions.length) return;
    try {
      const data = await apiCall(BUTTONS_URL, "GET");
      pinOptions = Array.isArray(data?.chores) ? data.chores : [];
      paintPinList();
    } catch (e) {
      // The list still shows; only the names of unloaded chores are missing.
    }
  }

  pinAddEl?.addEventListener("click", async () => {
    if (!pinOptions.length) await paintPins();
    const chore = await chorePicker.open({
      options: pinOptions, exclude: pinnedIds(), title: "Pin a chore to this board",
    });
    if (chore) savePins([...pinnedIds(), Number(chore.id)]);
  });

  // ---- managing credit buttons ----
  //
  // A credit button marks one chore done and credits a chosen person. The whole
  // manager lives inside the group picker: a board on a wall doesn't want a
  // settings gear over the circles, and buttons belong to the group the picker
  // is already about.

  // Every chore the household can see, for the Completes picker to search. Filled
  // on each manager open; filtered client-side as they type.
  let choreOptions = [];
  // The current user's id, so a new button credits them by default.
  let meId = null;
  // A button crediting nobody in particular: a board that asks who did each
  // chore asks, any other credits whoever pressed it.
  const WHOEVER = "Whoever did it";

  function fillOptions(select, options, selectedId) {
    if (!select) return;
    select.innerHTML = "";
    (options || []).forEach((opt) => {
      const o = document.createElement("option");
      o.value = String(opt.id);
      o.textContent = opt.name;
      if (selectedId != null && String(opt.id) === String(selectedId))
        o.selected = true;
      select.appendChild(o);
    });
  }

  // What the Completes button says: the chosen chore, or that one is wanted.
  function showChosenChore(chore) {
    if (bbChoreIdEl) bbChoreIdEl.value = chore ? String(chore.id) : "";
    if (!bbChorePickEl) return;
    bbChorePickEl.replaceChildren();
    if (!chore) {
      bbChorePickEl.textContent = "Pick a chore…";
      return;
    }
    const full = choreOptions.find((c) => String(c.id) === String(chore.id)) || chore;
    if (full.icon_kind) bbChorePickEl.appendChild(iconNode(full));
    bbChorePickEl.append(document.createTextNode(full.name || chore.name || ""));
  }

  // The form lives in its own dialog, opened by "+ New" or a row tapped to edit.
  function showButtonForm(open) {
    if (!bbDialogEl) return;
    if (open && !bbDialogEl.open) bbDialogEl.showModal();
    if (!open && bbDialogEl.open) bbDialogEl.close();
  }

  function resetButtonForm() {
    if (!bbFormEl) return;
    showButtonForm(false);
    bbDirty = false;
    paintDirty();
    if (bbTitleEl) bbTitleEl.textContent = "New credit button";
    if (bbIdEl) bbIdEl.value = "";
    if (bbLabelEl) bbLabelEl.value = "";
    // A new button defaults to the groups the board is watching — the common
    // case is a button for the board you're on.
    if (bbTagsEl) bbTagsEl.value = tags.join(", ");
    if (bbColorEl) bbColorEl.value = "#94A3B8";
    showChosenChore(null);
    // The next paint re-applies the "credit me" default; editing sets an
    // explicit value after this and keeps its own.
    if (bbCreditEl && meId != null) bbCreditEl.value = String(meId);
    if (bbSaveEl) bbSaveEl.textContent = "Add button";
    if (bbErrorEl) {
      bbErrorEl.hidden = true;
      bbErrorEl.textContent = "";
    }
  }

  // Load an existing button into the form to edit it; the hidden id is what
  // flips the submit from create to update.
  function editButton(button) {
    if (bbIdEl) bbIdEl.value = String(button.id);
    if (bbLabelEl) bbLabelEl.value = button.label || "";
    if (bbTagsEl) bbTagsEl.value = (button.tags || []).join(", ");
    if (bbColorEl) bbColorEl.value = button.color || "#94A3B8";
    showChosenChore({ id: button.chore_id, name: button.chore_name });
    if (bbCreditEl) bbCreditEl.value = String(button.credit_user_id ?? "");
    if (bbSaveEl) bbSaveEl.textContent = "Save";
    if (bbTitleEl) bbTitleEl.textContent = "Edit credit button";
    showButtonForm(true);
    bbLabelEl?.focus();
  }

  async function paintButtons() {
    if (!bbSectionEl) return;

    // A button has to belong to a group, so the manager only appears once the
    // board watches at least one.
    bbSectionEl.hidden = !tags.length;
    if (!tags.length) return;

    try {
      const data = await apiCall(`${BUTTONS_URL}?tags=${encodeURIComponent(tags.join(","))}`, "GET");
      choreOptions = Array.isArray(data?.chores) ? data.chores : [];
      if (data?.me != null) meId = data.me;
      // Keep an editing or changed selection; otherwise default a fresh form to
      // crediting me. ("" is a real choice now - whoever did it.)
      fillOptions(
        bbCreditEl,
        [{ id: "", name: WHOEVER }, ...(data?.members || [])],
        bbIdEl?.value || bbDirty ? bbCreditEl?.value : meId,
      );

      if (!bbListEl) return;
      bbListEl.innerHTML = "";
      const buttons = Array.isArray(data?.buttons) ? data.buttons : [];
      if (buttons.length === 0) {
        const none = document.createElement("p");
        none.className = "byte-board-tag-empty";
        none.textContent = "No credit buttons on this board yet.";
        bbListEl.appendChild(none);
        return;
      }

      buttons.forEach((button) => {
        const row = document.createElement("div");
        row.className = "byte-board-button-row";

        const edit = document.createElement("button");
        edit.type = "button";
        edit.className = "byte-board-button-edit";
        edit.dataset.bbEdit = String(button.id);
        // The row doubles as the edit control; the swatch and who-it-credits read
        // at a glance so the list isn't a wall of identical pills.
        edit.innerHTML = "";
        const swatch = document.createElement("span");
        swatch.className = "byte-board-button-swatch";
        if (button.color) swatch.style.background = button.color;
        const text = document.createElement("span");
        text.className = "byte-board-button-label";
        text.textContent = button.label;
        const who = document.createElement("span");
        who.className = "byte-board-button-who";
        who.textContent = `${button.chore_name} → ${button.credit_user_name || WHOEVER}`;
        edit.append(swatch, text, who);

        const del = document.createElement("button");
        del.type = "button";
        del.className = "byte-board-button-del";
        del.dataset.bbDelete = String(button.id);
        del.setAttribute("aria-label", `Delete ${button.label}`);
        del.textContent = "×";

        // Stash the row so a tap can load it into the form without a refetch.
        edit._button = button;
        row.append(edit, del);
        bbListEl.appendChild(row);
      });
    } catch (e) {
      // Leave the manager as it was; the board itself still works.
    }
  }

  async function submitButton(e) {
    e.preventDefault();
    if (!bbFormEl) return;

    // The hidden id, set only by choosing from the dropdown — so a half-typed
    // search that matches nothing can't submit as a chore.
    if (!bbChoreIdEl?.value) {
      if (bbErrorEl) {
        bbErrorEl.hidden = false;
        bbErrorEl.textContent = "Pick a chore from the search list.";
      }
      return;
    }

    const payload = {
      tags_csv: bbTagsEl?.value ?? tags.join(", "),
      label: bbLabelEl?.value.trim(),
      color: bbColorEl?.value,
      chore_id: bbChoreIdEl.value,
      credit_user_id: bbCreditEl?.value,
    };
    const id = bbIdEl?.value;

    try {
      if (id) await apiCall(BUTTON_URL(id), "PATCH", { button: payload });
      else await apiCall(BUTTONS_URL, "POST", { button: payload });

      resetButtonForm();
      flashSaved();
      await paintButtons();
      resync();
    } catch (err) {
      if (bbErrorEl) {
        bbErrorEl.hidden = false;
        bbErrorEl.textContent = "Couldn't save that button — check the fields.";
      }
    }
  }

  async function deleteButton(id) {
    try {
      await apiCall(BUTTON_URL(id), "DELETE");
      if (bbIdEl?.value === String(id)) resetButtonForm();
      flashSaved();
      await paintButtons();
      resync();
    } catch (e) {
      // Leave it; a failed delete just means the row is still there to try again.
    }
  }

  // ---- task buttons ----
  //
  // Saved from the settings, put straight on the pad (or taken off it) where
  // the server would have it - after the other buttons, before the chores -
  // and the resync the save broadcasts confirms it without a flash.
  function placeAction(item, show) {
    const at = base.findIndex((i) => i.kind === item.kind && String(i.id) === String(item.id));
    if (!show) {
      if (at >= 0) base.splice(at, 1);
    } else if (at >= 0) {
      base[at] = item;
    } else {
      const firstChore = base.findIndex((i) => (i.kind || "chore") === "chore");
      base.splice(firstChore < 0 ? base.length : firstChore, 0, item);
    }
    keep();
    items = withQueued(base);
    paint();
  }

  const taskButtons = initBoardTaskButtons({
    root,
    apiCall,
    tagsFn: () => tags,
    conversationIdFn,
    flashSaved,
    onSaved: (item, show) => item && placeAction(item, show),
    onRemoved: (id) => placeAction({ kind: "task", id }, false),
    onReordered: () => resync(),
  });

  // ---- circle size ----

  const scaleValueEl = root.querySelector("[data-board-scale-value]");

  function readScale() {
    try {
      return Number(window.localStorage.getItem(SCALE_KEY(conversationIdFn?.()))) || 100;
    } catch (e) {
      return 100;
    }
  }

  function applyScale(pct) {
    const next = Math.min(SCALE_MAX, Math.max(SCALE_MIN, Number(pct) || 100));
    root.style.setProperty("--board-circle-scale", String(next / 100));
    if (scaleValueEl) scaleValueEl.textContent = `${next}%`;
    return next;
  }

  function nudgeScale(delta) {
    const next = applyScale(readScale() + delta);
    try {
      window.localStorage.setItem(SCALE_KEY(conversationIdFn?.()), String(next));
    } catch (e) {
      // Blocked storage: it still changed on screen, it just won't be
      // remembered past a reload.
    }
  }

  applyScale(readScale());
  root
    .querySelector("[data-board-scale-smaller]")
    ?.addEventListener("click", () => nudgeScale(-SCALE_STEP));
  root
    .querySelector("[data-board-scale-bigger]")
    ?.addEventListener("click", () => nudgeScale(SCALE_STEP));

  // ---- waking up ----

  // A board is left on. Nothing about it changes when the room empties, so the
  // only signal that it has been ignored for hours is the clock — hence a
  // stamp rather than a visibility count. Written on every foreground, so the
  // gap measured is genuinely time nobody was here.
  function markSeen() {
    try {
      window.localStorage.setItem(WAKE_KEY, String(Date.now()));
    } catch (e) {
      // Private mode, blocked storage. The yawn is a nicety; losing it costs
      // nothing and must not take the board down with it.
    }
  }

  function maybeYawn() {
    let last = 0;
    try {
      last = Number(window.localStorage.getItem(WAKE_KEY) || 0);
    } catch (e) {
      return markSeen();
    }
    markSeen();
    // A first-ever load has no stamp to compare against, and greeting somebody
    // with a yawn because the browser is new reads as a bug.
    if (!last || Date.now() - last < WAKE_AFTER_MS) return;

    cheer(null, "wake");
  }

  // ---- wiring ----

  if (padEl) {
    // One listener for the whole pad rather than handlers per cell, since the
    // pad rebuilds itself whenever the set changes. The corner buttons are
    // checked FIRST: they sit on top of the disc, so a press on one is also a
    // press inside it, and reading the disc first would complete the chore
    // every time somebody skipped it.
    padEl.addEventListener("click", (e) => {
      const day = e.target.closest("[data-board-skip-day]");
      if (day) return dismiss(day.dataset.boardSkipDay, "day");

      const cycle = e.target.closest("[data-board-skip-cycle]");
      if (cycle) return skipCycle(cycle.dataset.boardSkipCycle);

      const undo = e.target.closest("[data-board-undo]");
      if (undo) return bringBack(undo.dataset.boardUndo);

      const listUndoEl = e.target.closest("[data-board-list-undo]");
      if (listUndoEl) return listUndo(listUndoEl.dataset.boardListUndo);

      const press = e.target.closest("[data-board-complete]");
      if (!press) return;

      // A long-press already ran the undo and set this flag; swallow the click
      // the browser fires at the end of the same press so it doesn't complete
      // the chore straight back after it was just taken off.
      if (press.dataset.suppressClick === "1") {
        delete press.dataset.suppressClick;
        return;
      }

      // The kind rides on the button, so a press resolves to the right item even
      // where items of different kinds share an id.
      const kind = press.dataset.boardKind;
      const item = find(press.dataset.boardComplete, kind);
      if (!item) return;

      // A trigger fires, a credit button credits, a chore completes. A chore
      // already put away is not completable by a stray press on its grey circle -
      // its own corner carries Undo, the only thing a press on it could mean.
      if (isTrigger(item)) return fire(item.id);
      if (isCredit(item)) return creditPress(item.id);
      if (isTask(item)) return taskPress(item.id);
      if (isList(item)) return listCheck(item.id);
      if (item.dismissed || item.skipped_today) return;

      return complete(item.id);
    });

    // Hold a chore to undo it - the same long-press the chores page carries, so
    // a mis-tap costs one gesture rather than a hunt for a corner. It only arms
    // on a chore with something to take back (a trigger fires, a credit button
    // credits - neither has an occurrence to undo), and a drag past a few pixels
    // cancels it so a scroll on a touch tablet doesn't read as a hold. A fired
    // hold flags the circle so the trailing click doesn't complete it again.
    const LONG_MS = 550;
    const MOVE_THRESHOLD = 8;
    const hold = {
      pointerId: null, pressEl: null, startX: 0, startY: 0, moved: false,
      fired: false, timer: null,
    };
    const resetHold = () => {
      if (hold.timer) window.clearTimeout(hold.timer);
      hold.pointerId = null; hold.pressEl = null; hold.startX = 0; hold.startY = 0;
      hold.moved = false; hold.fired = false; hold.timer = null;
    };

    padEl.addEventListener("pointerdown", (e) => {
      if (hold.pointerId !== null) return;

      const pressEl = e.target.closest("[data-board-complete]");
      if (!pressEl || pressEl.dataset.boardKind !== "chore") return;

      const chore = find(pressEl.dataset.boardComplete, "chore");
      if (!chore) return;

      // Nothing to take back on a fresh, untouched chore - don't arm a DELETE
      // that would only 404.
      const undoable =
        chore.progress_count > 0 || chore.dismissed || chore.skipped_today;
      if (!undoable) return;

      hold.pointerId = e.pointerId;
      hold.pressEl = pressEl;
      hold.startX = e.clientX;
      hold.startY = e.clientY;
      hold.moved = false;
      hold.fired = false;
      hold.timer = window.setTimeout(() => {
        if (!hold.pressEl || hold.moved) return;
        hold.fired = true;
        const id = pressEl.dataset.boardComplete;
        // Whichever way it was put away: a skipped/dismissed chore comes back
        // on the board, a done one has its last completion removed.
        if (chore.dismissed || chore.skipped_today) bringBack(id);
        else undoComplete(id);
      }, LONG_MS);
    });

    padEl.addEventListener("pointermove", (e) => {
      if (hold.pointerId !== e.pointerId) return;
      if (
        Math.hypot(e.clientX - hold.startX, e.clientY - hold.startY) >
        MOVE_THRESHOLD
      ) {
        hold.moved = true;
        if (hold.timer) {
          window.clearTimeout(hold.timer);
          hold.timer = null;
        }
      }
    });

    padEl.addEventListener("pointerup", (e) => {
      if (hold.pointerId !== e.pointerId) return;
      const pressEl = hold.pressEl;
      const fired = hold.fired;
      resetHold();
      if (fired && pressEl) pressEl.dataset.suppressClick = "1";
    });

    ["pointercancel", "pointerleave"].forEach((evt) =>
      padEl.addEventListener(evt, (e) => {
        if (hold.pointerId === e.pointerId) resetHold();
      }),
    );
  }

  if (tagToggleEl && tagPickerEl) {
    tagToggleEl.setAttribute("aria-expanded", "false");
    tagToggleEl.addEventListener("click", () => {
      const open = tagPickerEl.hidden;
      tagPickerEl.hidden = !open;
      // Also what holds the control at full opacity while the list is down -
      // it sits at 0.35 the rest of the time so it doesn't compete with the
      // circles, and a setting half faded out while you are using it reads as
      // disabled.
      tagToggleEl.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) {
        paintTagPicker();
        resetButtonForm();
        paintButtons();
        taskButtons.refresh();
        paintPins();
      }
    });
  }

  // Put away like a modal: a tap anywhere outside it, or Escape. Anything typed
  // and unsaved stays in its field for the next open.
  function closePicker() {
    if (!tagPickerEl || tagPickerEl.hidden) return;
    tagPickerEl.hidden = true;
    tagToggleEl?.setAttribute("aria-expanded", "false");
  }
  if (tagPickerEl) {
    document.addEventListener("pointerdown", (e) => {
      if (tagPickerEl.hidden) return;
      if (tagPickerEl.contains(e.target) || tagToggleEl?.contains(e.target)) return;
      // A dialog opened from the panel is still the panel's business.
      if (e.target.closest?.("dialog[open]")) return;
      closePicker();
      // The tap that closes it does only that, as with a modal: a chore circle
      // under it must not be pressed on the way.
      const swallow = (click) => {
        click.preventDefault();
        click.stopPropagation();
      };
      document.addEventListener("click", swallow, { capture: true, once: true });
      window.setTimeout(() => document.removeEventListener("click", swallow, true), 600);
    }, true);
    document.addEventListener("keydown", (e) => {
      // Escape inside a dialog closes just the dialog.
      if (e.key === "Escape" && !document.querySelector("dialog[open]")) closePicker();
    });
  }

  // Whose chores: save the ticked members and re-scope the pad. Like the group
  // toggles, each change saves on its own and the board reflects it at once.
  async function saveMembers() {
    const conversationId = conversationIdFn ? conversationIdFn() : null;
    if (!membersUrl || !conversationId) return;

    const ids = memberBoxes.filter((b) => b.checked).map((b) => parseInt(b.value, 10));
    try {
      await apiCall(membersUrl, "POST", { conversation_id: conversationId, member_ids: ids });
      flashSaved();
      resync();
    } catch (e) {
      // Leave the board showing whatever it showed; the ticks are the request.
    }
  }
  memberBoxes.forEach((box) => box.addEventListener("change", saveMembers));

  // This board's name and household sharing — owner-only, so the section is
  // only rendered for the owner.
  const settingsEl = root.querySelector("[data-board-settings]");
  const renameFormEl = root.querySelector("[data-board-rename-form]");
  const renameInputEl = root.querySelector("[data-board-rename-input]");
  const renameSaveEl = root.querySelector("[data-board-rename-save]");
  const shareBoxEl = root.querySelector("[data-board-share]");
  const doerEl = root.querySelector("[data-board-doer]");
  const dreamOpenEl = root.querySelector("[data-board-dream-open]");
  const dreamSummaryEl = root.querySelector("[data-board-dream-summary]");
  const dreamDialogEl = root.querySelector("[data-board-dream-dialog]");
  const dreamFormEl = root.querySelector("[data-board-dream-form]");

  if (renameFormEl && renameInputEl) {
    let savedName = renameInputEl.value;
    const syncRenameSave = () => {
      const name = renameInputEl.value.trim();
      if (renameSaveEl) renameSaveEl.disabled = !name || name === savedName;
      paintDirty();
    };
    syncRenameSave();
    renameInputEl.addEventListener("input", syncRenameSave);

    renameFormEl.addEventListener("submit", async (e) => {
      e.preventDefault();
      const name = renameInputEl.value.trim();
      if (!name || name === savedName) return;

      try {
        await apiCall(renameFormEl.dataset.url, "PATCH", { name });
        savedName = name;
        renameInputEl.blur();
        flashSaved();
      } catch (err) {
        renameInputEl.value = savedName;
      }
      syncRenameSave();
    });
  }

  // The box reflects what's stored; a flip that doesn't land reverts, so the
  // switch never lies about what the household can see.
  if (settingsEl && shareBoxEl) {
    shareBoxEl.addEventListener("change", async () => {
      const shared = shareBoxEl.checked;
      const conversationId = conversationIdFn ? conversationIdFn() : null;
      try {
        await apiCall(settingsEl.dataset.shareUrl, "POST", { conversation_id: conversationId, shared });
        // Shared, it shows the household's timers too.
        app.dataset.timerBoardShared = String(shared);
        app.dispatchEvent(new CustomEvent("board:placement-changed"));
        flashSaved();
      } catch (err) {
        shareBoxEl.checked = !shared;
      }
    });
  }

  // The connected list: the row says which list and when checked items leave,
  // and opens the dialog, which saves as a whole. Closing it unsaved puts the
  // fields back.
  const listOpenEl = root.querySelector("[data-board-list-open]");
  const listSummaryEl = root.querySelector("[data-board-list-summary]");
  const listDialogEl = root.querySelector("[data-board-list-dialog]");
  const listFormEl = root.querySelector("[data-board-list-form]");
  const listErrorEl = root.querySelector("[data-board-list-error]");
  const listClearEl = root.querySelector("[data-board-list-clear]");
  const listClearReadEl = root.querySelector("[data-board-list-clear-read]");
  if (listClearEl) listClearEl.placeholder = DURATION_PLACEHOLDER;

  // The readback under the box, and the box set aside while the end of the day
  // is ticked.
  function paintClearAfter() {
    if (!listFormEl) return;
    const endOfDay = listFormEl.elements.clear_end_of_day.checked;
    listClearEl.disabled = endOfDay;
    const raw = listClearEl.value.trim();
    listClearReadEl.textContent = endOfDay ? "" : raw === "0" ? "Straight away" : durationRead(raw);
    listClearReadEl.dataset.unreadable = String(!endOfDay && !!raw && parseDuration(raw) == null);
  }
  let boardList = {};
  try {
    boardList = JSON.parse(app.dataset.boardList || "{}") || {};
  } catch (e) {
    boardList = {};
  }

  function paintBoardList() {
    if (listSummaryEl) listSummaryEl.textContent = listSummary(boardList);
    if (!listFormEl || listDialogEl?.open) return;
    const f = listFormEl.elements;
    f.list_id.value = boardList.list_id ? String(boardList.list_id) : "";
    const clear = String(boardList.clear_after ?? 3600);
    f.clear_end_of_day.checked = clear === "end_of_day";
    f.clear_after.value = clear === "end_of_day" ? "" : formatDurationShort(Number(clear));
    paintClearAfter();
    f.very_high.value = boardList.very_high ?? "Very High";
    f.high.value = boardList.high ?? "High";
    if (listErrorEl) listErrorEl.hidden = true;
  }
  paintBoardList();

  listOpenEl?.addEventListener("click", () => listDialogEl?.showModal());
  root.querySelector("[data-board-list-cancel]")?.addEventListener("click", () => listDialogEl?.close());
  listDialogEl?.addEventListener("close", paintBoardList);
  listFormEl?.addEventListener("input", paintClearAfter);
  listFormEl?.addEventListener("change", paintClearAfter);
  listFormEl?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = listFormEl.elements;
    const raw = f.clear_after.value.trim();
    const seconds = raw === "0" ? 0 : parseDuration(raw);
    if (!f.clear_end_of_day.checked && seconds == null) {
      listErrorEl.textContent = "Say how long checked items stay, like 30s, 5m or 1h.";
      listErrorEl.hidden = false;
      return;
    }
    try {
      const data = await apiCall(listFormEl.dataset.url, "POST", {
        conversation_id: conversationIdFn ? conversationIdFn() : null,
        list_id: f.list_id.value,
        clear_after: f.clear_end_of_day.checked ? "end_of_day" : String(seconds),
        very_high: f.very_high.value,
        high: f.high.value,
      });
      boardList = data?.list || {};
      listDialogEl.close();
      flashSaved();
      resync();
    } catch (err) {
      if (!listErrorEl) return;
      listErrorEl.textContent = err.body?.error || "Couldn't save that.";
      listErrorEl.hidden = false;
    }
  });

  // Hot-chore dreams: the row in settings says how they're set and opens the
  // dialog, which saves as a whole. Closing it unsaved puts the fields back to
  // what's stored.
  let dreamsOn = app.dataset.boardChoreDreams !== "false";
  let dreamPace = paceFromMeta(JSON.parse(app.dataset.boardDreamPace || "{}"));

  function paintDreams() {
    if (dreamSummaryEl) dreamSummaryEl.textContent = dreamSummary(dreamsOn, dreamPace);
    if (!dreamFormEl || dreamDialogEl?.open) return;
    const f = dreamFormEl.elements;
    f.on.value = String(dreamsOn);
    f.every.value = String(dreamPace.every);
    f.blank.value = String(dreamPace.blank);
    f.rest.value = String(dreamPace.rest);
    f.quiet_from.value = dreamPace.quietFrom === null ? "" : String(dreamPace.quietFrom);
    f.quiet_to.value = dreamPace.quietTo === null ? "" : String(dreamPace.quietTo);
  }
  paintDreams();

  dreamOpenEl?.addEventListener("click", () => dreamDialogEl?.showModal());
  root.querySelector("[data-board-dream-cancel]")?.addEventListener("click", () => dreamDialogEl?.close());
  dreamDialogEl?.addEventListener("close", paintDreams);
  dreamFormEl?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = dreamFormEl.elements;
    const body = {
      conversation_id: conversationIdFn ? conversationIdFn() : null,
      on: f.on.value === "true",
      every: f.every.value,
      blank: f.blank.value,
      rest: f.rest.value,
      quiet_from: f.quiet_from.value,
      quiet_to: f.quiet_to.value,
    };
    try {
      await apiCall(settingsEl.dataset.choreDreamsUrl, "POST", body);
      dreamsOn = body.on;
      dreamPace = paceFromMeta({
        dream_minutes: body.every,
        dream_blank_percent: body.blank,
        dream_rest_minutes: body.rest,
        dream_quiet_from: body.quiet_from,
        dream_quiet_to: body.quiet_to,
      });
      app.dataset.boardChoreDreams = String(dreamsOn);
      onChoreDreamsChanged?.(dreamsOn);
      onDreamPaceChanged?.(dreamPace);
      dreamDialogEl.close();
      flashSaved();
    } catch (err) {
      // Left open with what they chose, so a retry is one tap.
    }
  });

  // Who a press here is done by. One that doesn't land goes back to the last
  // value that did.
  let savedDoer = doerEl ? doerEl.value : "";
  if (settingsEl && doerEl) {
    doerEl.addEventListener("change", async () => {
      const conversationId = conversationIdFn ? conversationIdFn() : null;
      try {
        await apiCall(settingsEl.dataset.doerUrl, "POST", { conversation_id: conversationId, doer: doerEl.value });
        savedDoer = doerEl.value;
        flashSaved();
      } catch (err) {
        doerEl.value = savedDoer;
      }
    });
  }

  if (tagListEl) {
    tagListEl.addEventListener("click", (e) => {
      const pick = e.target.closest("[data-board-pick-tag]");
      if (pick) toggleTag(pick.dataset.boardPickTag);
    });
  }

  // What this board keeps off, as a search. Typed, so it saves with its button
  // (lit only while there's a change), and a search the server can't read comes
  // back with the reason instead of being stored.
  const hiddenFormEl = root.querySelector("[data-board-hidden-form]");
  const hiddenInputEl = root.querySelector("[data-board-hidden-input]");
  const hiddenSaveEl = root.querySelector("[data-board-hidden-save]");
  const hiddenErrorEl = root.querySelector("[data-board-hidden-error]");
  let savedFilter = hiddenInputEl?.value.trim() || "";
  const syncHiddenSave = () => {
    if (hiddenSaveEl) hiddenSaveEl.disabled = hiddenInputEl.value.trim() === savedFilter;
    paintDirty();
  };
  const showHiddenError = (text) => {
    if (!hiddenErrorEl) return;
    hiddenErrorEl.hidden = !text;
    hiddenErrorEl.textContent = text || "";
  };

  if (hiddenFormEl && hiddenInputEl) {
    syncHiddenSave();
    hiddenInputEl.addEventListener("input", () => {
      showHiddenError("");
      syncHiddenSave();
    });

    hiddenFormEl.addEventListener("submit", async (e) => {
      e.preventDefault();
      const filter = hiddenInputEl.value.trim();
      if (filter === savedFilter) return;

      try {
        const data = await apiCall(hiddenFormEl.dataset.url, "POST", {
          conversation_id: conversationIdFn ? conversationIdFn() : null,
          filter,
        });
        savedFilter = data?.hidden_filter ?? filter;
        hiddenInputEl.value = savedFilter;
        showHiddenError("");
        flashSaved();
        resync();
      } catch (err) {
        showHiddenError(err.body?.error ? `Couldn't read that: ${err.body.error}` : "Couldn't save that.");
      }
      syncHiddenSave();
    });
  }

  if (bbFormEl) {
    bbFormEl.addEventListener("submit", submitButton);
    const markDirty = () => {
      bbDirty = true;
      paintDirty();
    };
    bbFormEl.addEventListener("input", markDirty);
    bbFormEl.addEventListener("change", markDirty);
  }
  if (bbNewEl) {
    bbNewEl.addEventListener("click", () => {
      resetButtonForm();
      showButtonForm(true);
      bbLabelEl?.focus();
    });
  }
  if (bbCancelEl) bbCancelEl.addEventListener("click", resetButtonForm);
  // Escape closes the dialog natively; drop the draft with it.
  bbDialogEl?.addEventListener("close", () => {
    if (bbDirty || bbIdEl?.value) resetButtonForm();
  });

  bbChorePickEl?.addEventListener("click", async () => {
    const chore = await chorePicker.open({ options: choreOptions, title: "What does it complete?" });
    if (!chore) return;
    showChosenChore(chore);
    bbDirty = true;
    paintDirty();
  });

  if (bbListEl) {
    bbListEl.addEventListener("click", (e) => {
      const del = e.target.closest("[data-bb-delete]");
      if (del) return deleteButton(del.dataset.bbDelete);

      const edit = e.target.closest("[data-bb-edit]");
      if (edit?._button) editButton(edit._button);
    });
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;

    maybeYawn();
    queue.flush().then(resync);
  });
  // The connection is back: whatever was pressed without it goes out now.
  window.addEventListener("online", () => queue.flush());

  paint();
  maybeYawn();
  // Anything pressed before the last reload that never made it.
  queue.flush();

  return {
    // A chores broadcast landed. The envelope says only that something
    // changed and who did it, not what it changed to, so this asks — the same
    // thing /chores/today does with the same signal.
    onChoresChanged() {
      resync();
    },

    // The socket came back. Anything pressed while it was down goes out now,
    // and it finishes BEFORE the resync, so the fetch answers with them in.
    async onReconnect() {
      await queue.flush();
      await resync();
    },

    // The board was repointed on another device. Apply the new groups without
    // re-saving them (the change came FROM the server) — same repaint the local
    // toggle does. No onTagsChanged callback: the caller already knows.
    setTags(next) {
      const same =
        Array.isArray(next) &&
        next.length === tags.length &&
        next.every((t, i) => String(t).toLowerCase() === String(tags[i]).toLowerCase());
      if (same) return;
      applyTags(next);
    },

    // Pinned or unpinned elsewhere (another screen, or the board's Buddy):
    // take the new set. The broadcast that carried it fetches the board again.
    setPins(ids) {
      const next = JSON.stringify((Array.isArray(ids) ? ids : []).map(Number));
      if (next === JSON.stringify(pinnedIds())) return;
      app.dataset.boardPins = next;
      paintPins();
    },

    // The connected list changed: fetch the board again if it's this one's.
    onListChanged(listId) {
      if (String(listId) === String(boardList.list_id)) resyncSoon();
    },

    // Set on another device: keep the row and dialog honest.
    setBoardList(meta) {
      const raw = meta || {};
      const same = String(raw.list_id || "") === String(boardList.list_id || "");
      boardList = { ...raw, list_name: same ? boardList.list_name : null };
      paintBoardList();
    },

    // Switched on another device: keep the controls honest.
    setDreamPace(pace) {
      dreamPace = pace;
      paintDreams();
    },
    setChoreDreams(on) {
      app.dataset.boardChoreDreams = String(on);
      dreamsOn = on;
      paintDreams();
    },

    // The server decides who a press credits, so this only keeps the select honest.
    setDoer(value) {
      savedDoer = value;
      if (doerEl) doerEl.value = value;
    },

    // Changed on another device: follow it without saving it back, and leave
    // the field alone while someone here is typing in it.
    setHiddenFilter(next) {
      const filter = String(next || "");
      if (filter === savedFilter) return;
      savedFilter = filter;
      if (hiddenInputEl && document.activeElement !== hiddenInputEl) hiddenInputEl.value = filter;
      if (hiddenInputEl) syncHiddenSave();
      resync();
    },

    resync,
  };
}
