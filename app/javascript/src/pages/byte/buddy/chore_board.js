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

// Managing credit buttons: list/create at the collection, update/delete at one.
const BUTTONS_URL = "/byte/board/buttons";
const BUTTON_URL = (id) => `/byte/board/buttons/${id}`;

// A board item is one of three kinds, stamped by the server in `kind`:
//   * CHORE   — tick to complete, has state (ring, count, skips).
//   * TRIGGER — a routine, tapped to fire, no occurrence to settle.
//   * CREDIT  — a custom button that completes a chore crediting a chosen person.
// Triggers and credit buttons are both stateless ACTION circles: one press, a
// flash, nothing to undo. Chores are the only stateful kind.
function isTrigger(item) {
  return item && item.kind === "trigger";
}
function isCredit(item) {
  return item && item.kind === "credit";
}
function isAction(item) {
  return isTrigger(item) || isCredit(item);
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
// A press that FAILS is the case that needs saying out loud, and it gets the
// same amber dot the chores page paints on a confirmed failure. It is retried
// on the next foreground or socket reconnect, which is also when the board
// resyncs anyway.

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
  if (!res.ok) throw new Error(`http_${res.status}`);
  if (res.status === 204) return null;
  return res.json();
}

// Which of the four states a cell is in, most settled first. Order matters:
// a chore can be both done and waved off (somebody did it after skipping it),
// and what it should read as is done.
function cellState(item) {
  // An action (trigger or credit button) has no occurrence to be done, skipped
  // or waved off - it is only ever "there to press", so it gets its own settled
  // state and none of the ring/corner machinery the four chore states drive.
  if (isAction(item)) return item.kind;
  if (item.progress_count >= item.target_count) return "done";
  if (item.skipped_today) return "skipped";
  if (item.dismissed) return "dismissed";
  return "open";
}

// Only what is being asked for today. `today_visible` is the same field
// /chores/today sorts on, so the board and the page agree about what the day
// holds without this knowing anything about recurrence.
//
// A dismissed or skipped chore is KEPT and greyed rather than dropped: it was
// on the board a moment ago and vanishing on a press reads as a mis-tap, and
// the grey circle is also the only way back to it.
function onBoard(items) {
  return items.filter((item) =>
    isAction(item) ? true : item.today_visible && !item.archived,
  );
}

// A whole number prints bare (2×), a fractional one keeps its places (1.5×).
// Mirrors the chores page so a multiplier reads the same on every surface.
function formatMultiplier(n) {
  if (n == null) return "";
  const f = Number(n);
  return f === Math.floor(f) ? String(Math.floor(f)) : String(f);
}

// The icon, in whatever shape it arrived. Mirrors the four kinds the chore
// serializer resolves (`icon_kind`) rather than guessing from the string, so a
// glyph that happens to look like a path can't be read as one.
function iconNode(chore) {
  // The BOX is what the container query measures, so the glyph always goes
  // inside one even when it is a single character - that is what makes an
  // emoji and an uploaded image render at the same visual size, and it is how
  // the chores page does it.
  const box = document.createElement("span");
  box.className = "byte-board-icon";

  if (chore.icon_kind === "image" || chore.icon_kind === "svg") {
    const img = document.createElement("img");
    img.className = "byte-board-icon-img";
    img.src = chore.icon;
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

export function initChoreBoard({ root, app, conversationIdFn, sayText } = {}) {
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
  const bbLabelEl = root.querySelector("[data-bb-label]");
  // The groups a new/edited button belongs to, comma-separated.
  const bbTagsEl = root.querySelector("[data-bb-tags]");
  // Completes: a type-to-find picker. The text field searches; the hidden input
  // holds the chosen chore id; the results box is the dropdown.
  const bbChoreSearchEl = root.querySelector("[data-bb-chore-search]");
  const bbChoreIdEl = root.querySelector("[data-bb-chore]");
  const bbChoreResultsEl = root.querySelector("[data-bb-chore-results]");
  const bbCreditEl = root.querySelector("[data-bb-credit]");
  const bbColorEl = root.querySelector("[data-bb-color]");
  const bbIdEl = root.querySelector("[data-bb-id]");
  const bbCancelEl = root.querySelector("[data-bb-cancel]");
  const bbSaveEl = root.querySelector("[data-bb-save]");
  const bbErrorEl = root.querySelector("[data-bb-error]");

  const cheerUrl = app.dataset.choreCheerUrl;
  // The board's own set endpoint, not /chores/sync: it answers with chores AND
  // triggers for the group, so a resync keeps the triggers on screen instead of
  // dropping them (the chores endpoint has never heard of them).
  const itemsUrl = app.dataset.boardItemsUrl;
  const tagUrl = app.dataset.boardTagUrl;
  const tagsUrl = app.dataset.boardTagsUrl;

  // The groups this board watches. Several, matched as "any": a chore, routine
  // or button in ANY of them appears here.
  let tags = [];
  try {
    tags = JSON.parse(app.dataset.boardTags || "[]");
  } catch (e) {
    tags = [];
  }
  const tagLabel = () => (tags.length ? tags.join(", ") : "Pick groups");
  let items = [];
  // Presses the server hasn't confirmed, by item id. A count rather than a
  // flag: a chore with a target of three gets pressed three times in a row and
  // the first answer back must not clear the other two.
  const inFlight = new Map();
  // Running flash timers for trigger cells, by id, so a second press restarts
  // the "Done!" rather than letting the first one's timeout clear it early.
  const flashTimers = new Map();
  // Presses that came back as a failure, kept so they can be tried again. In
  // memory only - the chores page writes its queue to localStorage before
  // touching the network, and matching that is a bigger piece of machinery
  // than this needs. A reload drops them, and the resync that follows shows
  // the true state rather than a lie.
  const failed = [];

  try {
    items = onBoard(JSON.parse(app.dataset.boardItems || "[]"));
  } catch (e) {
    items = [];
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
    emptyEl.hidden = tags.length > 0 && items.length > 0;
  }

  // Whether a press on this id is still in flight / came back failed. Shared by
  // both kinds, so a trigger's dim-while-sending reads the same as a chore's.
  function markPending(cell, id) {
    const waiting = (inFlight.get(String(id)) || 0) > 0;
    cell.dataset.sending = waiting ? "true" : "false";
    cell.dataset.syncPending = failed.some((f) => String(f.id) === String(id))
      ? "true"
      : "false";
  }

  function paintCell(cell, chore) {
    cell.dataset.state = cellState(chore);
    cell.dataset.boardCell = String(chore.id);

    // An action (trigger / credit button) is stateless: no ring, no count, no
    // skip/undo corners to show or hide. All a repaint does for one is keep its
    // sending/failed dot honest.
    if (isAction(chore)) {
      markPending(cell, chore.id);
      return;
    }

    // Who the done disc belongs to. Same `--actor-color` the chores page keys
    // its finished state off, carried here on data-actor so a chore I finished
    // reads in my colour rather than the board's flat default green. Anonymous
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

    // Derived here rather than left on the node, because `paint` replaces
    // every cell whenever the set changes and a flag written at press time
    // would be thrown away by the next household tap.
    markPending(cell, chore.id);
  }

  function buildCell(item) {
    return isAction(item) ? buildActionCell(item) : buildChoreCell(item);
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

  // Patched in place where the set hasn't changed, rebuilt when it has. A
  // tablet left on the counter repaints on every household tap, and swapping
  // every node each time kills the press animation mid-flourish and scrolls
  // the pad back to the top.
  function paint() {
    if (!padEl) return;

    // The three kinds come from different tables and can share an id, so the cell
    // key carries the kind too — otherwise two items with matching ids would read
    // as "same set" and paint one into the other's cell.
    const key = (item) => `${item.kind || "chore"}:${item.id}`;
    const wanted = items.map(key);
    const present = Array.from(padEl.children).map((el) => el.dataset.boardKey);
    const sameSet =
      wanted.length === present.length &&
      wanted.every((id, i) => id === present[i]);

    if (sameSet) {
      items.forEach((item, i) => paintCell(padEl.children[i], item));
    } else {
      padEl.innerHTML = "";
      items.forEach((item) => {
        const cell = buildCell(item);
        cell.dataset.boardKey = key(item);
        padEl.appendChild(cell);
      });
    }
    paintEmpty();
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
    const at = items.findIndex(
      (item) => (item.kind || "chore") === "chore" && item.id === fresh.id,
    );
    if (at >= 0) items[at] = { ...fresh, kind: "chore" };
    paint();

    // An `after_chore` follower coming due is a chore ARRIVING on the board,
    // which this can't fold in - the set changed rather than one row in it.
    if (Array.isArray(payload?.chores) && payload.chores.length > 0) resync();
  }

  // Re-pull the whole board - chores AND triggers of the group - from the
  // board's own endpoint. It already filters to the thread's tag server-side
  // and stays correct across the 4am rollover (it leans on /chores/today's own
  // serializer), so there is nothing to filter here and triggers come back on
  // the set instead of being dropped.
  async function resync() {
    if (!itemsUrl || !tags.length) return;

    const conversationId = conversationIdFn ? conversationIdFn() : null;
    const url = conversationId
      ? `${itemsUrl}?conversation_id=${encodeURIComponent(conversationId)}`
      : itemsUrl;

    try {
      const data = await apiCall(url, "GET");
      items = onBoard(Array.isArray(data?.items) ? data.items : []);
      paint();
    } catch (e) {
      // Leave what's on screen. The circles already there still work, and a
      // wall tablet that blanks itself on a blip is worse than a stale one.
    }
  }

  // ---- pressing things ----

  function hold(id, delta) {
    const key = String(id);
    const next = (inFlight.get(key) || 0) + delta;
    if (next > 0) inFlight.set(key, next);
    else inFlight.delete(key);
  }

  // What the chore WILL look like if the press lands, applied before the
  // request goes out. The server's answer overwrites it either way, so this is
  // a prediction and not a second source of truth - but it is what makes the
  // ring move under a finger instead of a few hundred milliseconds later.
  function predict(id, change) {
    // Only chores predict - a trigger has no state to move under a finger - so
    // the lookup is chore-scoped even where an id collides with a trigger's.
    const chore = find(id, "chore");
    if (!chore) return;

    const at = items.indexOf(chore);
    items[at] = { ...chore, ...change(chore) };
    paint();
  }

  // Remembered so it can be tried again, and so the cell can say that it
  // hasn't gone through. Deduplicated by chore and action: pressing a failing
  // button four times should leave one thing to retry, not four.
  function remember(id, run) {
    const key = String(id);
    if (!failed.some((f) => f.key === key)) failed.push({ id, key, run });
  }

  // Tried on the next foreground or socket reconnect - see resync, which both
  // of those already call. Each one is dropped from the list before it runs,
  // so a second failure re-adds it rather than stacking.
  async function drainFailed() {
    const queued = failed.splice(0, failed.length);
    paint();
    for (const item of queued) await item.run();
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

  // Every press runs through here: predict, hold, send, and either fold the
  // answer in or remember it to try again. `send` returns what to do with a
  // successful answer; the prediction is what the screen shows until then.
  //
  // The predicted state is deliberately NOT rolled back on failure. The tap
  // happened, it is being retried, and flipping the circle back would say the
  // press was ignored - which is the one thing that isn't true. The amber dot
  // is what says it hasn't landed yet, and the next resync is what corrects
  // the screen if the retry never succeeds.
  async function press(id, { change, send }) {
    predict(id, change);
    hold(id, 1);
    paint();

    try {
      await send();
      // Guarded: `findIndex` answers -1 for a press that never failed, and
      // `splice(-1, 1)` would quietly drop the LAST remembered press instead
      // of none of them.
      const at = failed.findIndex((f) => f.key === String(id));
      if (at >= 0) failed.splice(at, 1);
    } catch (e) {
      remember(id, () => press(id, { change, send }));
    } finally {
      hold(id, -1);
      paint();
    }
  }

  function complete(id) {
    const chore = find(id, "chore");
    if (!chore) return;

    return press(id, {
      // One more of today's target, capped - the ring fills tap by tap on a
      // chore asked for several times a day.
      change: (c) => ({
        progress_count: Math.min(c.progress_count + 1, c.target_count),
      }),
      send: async () => {
        const payload = await apiCall(COMPLETE_URL(id), "POST", {
          client_completed_at: new Date().toISOString(),
        });
        absorb(payload);
        cheer(find(id, "chore") || chore, "chore_done");
      },
    });
  }

  // Fire a trigger: run its routine, then flash the "Done!" over the disc. No
  // predict (nothing to move), and no `cheer` - the flash is the receipt, and a
  // "nice work" over a thing you set off rather than finished reads wrong. A
  // failure is remembered and retried on the next foreground/reconnect, same as
  // a chore press; the sending dot is what says it is on its way meanwhile.
  function fire(id) {
    if (!find(id, "trigger")) return;

    hold(id, 1);
    paint();

    return (async () => {
      try {
        await apiCall(RUN_URL(id), "POST", {
          conversation_id: conversationIdFn ? conversationIdFn() : null,
        });
        const at = failed.findIndex((f) => f.key === String(id));
        if (at >= 0) failed.splice(at, 1);
        flashCell(id, "trigger");
      } catch (e) {
        remember(id, () => fire(id));
      } finally {
        hold(id, -1);
        paint();
      }
    })();
  }

  // Credit a chore on someone's behalf: complete it crediting the button's
  // chosen member, then flash and fold the fresh chore back in so its own circle
  // (if it's on this board too) flips to done. Same predict-less, retry-on-fail
  // shape as a trigger fire.
  function creditPress(id) {
    if (!find(id, "credit")) return;

    hold(id, 1);
    paint();

    return (async () => {
      try {
        const payload = await apiCall(PRESS_URL(id), "POST", {});
        const at = failed.findIndex((f) => f.key === String(id));
        if (at >= 0) failed.splice(at, 1);
        absorb(payload);
        flashCell(id, "credit");
      } catch (e) {
        remember(id, () => creditPress(id));
      } finally {
        hold(id, -1);
        paint();
      }
    })();
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

  function dismiss(id, span) {
    return press(id, {
      change: () => ({ dismissed: true }),
      send: async () => {
        absorb(await apiCall(DISMISS_URL(id), "POST", { span }));
      },
    });
  }

  function skipCycle(id) {
    return press(id, {
      // A skip settles the WHOLE occurrence, so the circle reads as finished
      // rather than one-of-three done - the same clamp the serializer applies
      // server-side (see ChoreSerializer#progress_count).
      change: (c) => ({ skipped_today: true, progress_count: c.target_count }),
      send: async () => {
        await apiCall(SKIP_URL(id), "POST", {
          client_completed_at: new Date().toISOString(),
        });
        // The skip endpoint answers with a completion rather than a chore, so
        // there is nothing to fold in - ask for the row instead.
        await resync();
      },
    });
  }

  // Take the last completion back off - the hold gesture's undo for a chore
  // that's done (or part-done). The same DELETE the chores page's long-press
  // sends; the server removes this user's most recent completion today and
  // answers with the fresh chore, which folds straight back in. A 404 means
  // there was nothing left to undo (a race with a household tap, say), which is
  // the state the hold was reaching for anyway - resync rather than remembering
  // it as a failure to retry forever.
  function undoComplete(id) {
    const chore = find(id, "chore");
    if (!chore) return;

    return press(id, {
      change: (c) => ({ progress_count: Math.max(c.progress_count - 1, 0) }),
      send: async () => {
        try {
          absorb(await apiCall(COMPLETE_URL(id), "DELETE"));
        } catch (err) {
          if (String(err.message) === "http_404") return resync();
          throw err;
        }
      },
    });
  }

  function bringBack(id) {
    const chore = find(id, "chore");
    if (!chore) return;

    const wasDismissed = chore.dismissed;
    const wasSkipped = chore.skipped_today;
    return press(id, {
      change: () => ({
        dismissed: false,
        skipped_today: false,
        progress_count: wasSkipped ? 0 : chore.progress_count,
      }),
      send: async () => {
        // Whichever put it away. Both are reachable from the one control,
        // because "bring it back" is the same intent either way and the person
        // pressing it is not thinking about which mechanism was used.
        if (wasDismissed) await apiCall(DISMISS_URL(id), "DELETE");
        if (wasSkipped) await apiCall(SKIP_URL(id), "DELETE");
        await resync();
      },
    });
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
      tags = Array.isArray(data?.chore_tags) ? data.chore_tags : [];
      if (tagToggleEl) tagToggleEl.textContent = tagLabel();
      items = [];
      paint();
      resync();
      // The watched groups just changed under the manager, so which buttons it
      // shows and the chore it files a new one against have too - re-mark the
      // picker and repaint the buttons rather than leaving the old set showing.
      paintTagPicker();
      resetButtonForm();
      paintButtons();
    } catch (e) {
      // The screen keeps looking after whatever it was looking after.
    }
  }

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

  function hideChoreResults() {
    if (!bbChoreResultsEl) return;
    bbChoreResultsEl.hidden = true;
    bbChoreResultsEl.innerHTML = "";
    bbChoreSearchEl?.setAttribute("aria-expanded", "false");
  }

  // Pick a chore from the dropdown: the id goes to the hidden input (what the
  // form submits), the name fills the search field so it reads as chosen.
  function chooseChore(opt) {
    if (bbChoreIdEl) bbChoreIdEl.value = String(opt.id);
    if (bbChoreSearchEl) bbChoreSearchEl.value = opt.name;
    hideChoreResults();
  }

  // Substring match, capped so the dropdown stays a glanceable short list rather
  // than the giant select it replaced. A blank query shows the first few.
  function paintChoreResults(query) {
    if (!bbChoreResultsEl) return;

    const q = query.trim().toLowerCase();
    const matches = (q ? choreOptions.filter((c) => c.name.toLowerCase().includes(q)) : choreOptions).slice(0, 10);

    bbChoreResultsEl.innerHTML = "";
    if (matches.length === 0) {
      hideChoreResults();
      return;
    }

    matches.forEach((opt) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "byte-board-chore-result";
      row.dataset.bbChoreOption = String(opt.id);
      row.textContent = opt.name;
      row._option = opt;
      bbChoreResultsEl.appendChild(row);
    });
    bbChoreResultsEl.hidden = false;
    bbChoreSearchEl?.setAttribute("aria-expanded", "true");
  }

  // Typing clears any previous pick: the hidden id only means something while the
  // field still reads as the chore they chose. Re-choosing from the dropdown sets
  // it again.
  function onChoreInput() {
    if (bbChoreIdEl) bbChoreIdEl.value = "";
    paintChoreResults(bbChoreSearchEl?.value || "");
  }

  function resetButtonForm() {
    if (!bbFormEl) return;
    if (bbIdEl) bbIdEl.value = "";
    if (bbLabelEl) bbLabelEl.value = "";
    // A new button defaults to the groups the board is watching — the common
    // case is a button for the board you're on.
    if (bbTagsEl) bbTagsEl.value = tags.join(", ");
    if (bbColorEl) bbColorEl.value = "#16A34A";
    if (bbChoreSearchEl) bbChoreSearchEl.value = "";
    if (bbChoreIdEl) bbChoreIdEl.value = "";
    hideChoreResults();
    // Cleared so the next paint re-applies the "credit me" default; editing sets
    // an explicit value after this and isn't repainted, so it keeps its own.
    if (bbCreditEl) bbCreditEl.value = "";
    if (bbCancelEl) bbCancelEl.hidden = true;
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
    if (bbColorEl) bbColorEl.value = button.color || "#16A34A";
    if (bbChoreSearchEl) bbChoreSearchEl.value = button.chore_name || "";
    if (bbChoreIdEl) bbChoreIdEl.value = String(button.chore_id);
    hideChoreResults();
    if (bbCreditEl) bbCreditEl.value = String(button.credit_user_id);
    if (bbCancelEl) bbCancelEl.hidden = false;
    if (bbSaveEl) bbSaveEl.textContent = "Save";
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
      // Keep an editing selection; otherwise default a fresh form to crediting me.
      fillOptions(bbCreditEl, data?.members, bbCreditEl?.value || meId);

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
        who.textContent = `${button.chore_name} → ${button.credit_user_name}`;
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
      await paintButtons();
      resync();
    } catch (e) {
      // Leave it; a failed delete just means the row is still there to try again.
    }
  }

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
      }
    });
  }

  if (tagListEl) {
    tagListEl.addEventListener("click", (e) => {
      const pick = e.target.closest("[data-board-pick-tag]");
      if (pick) toggleTag(pick.dataset.boardPickTag);
    });
  }

  if (bbFormEl) bbFormEl.addEventListener("submit", submitButton);
  if (bbCancelEl) bbCancelEl.addEventListener("click", resetButtonForm);

  if (bbChoreSearchEl) {
    bbChoreSearchEl.addEventListener("input", onChoreInput);
    bbChoreSearchEl.addEventListener("focus", () =>
      paintChoreResults(bbChoreSearchEl.value || ""),
    );
    // A click on a result lands before this blur (mousedown fires first and the
    // handler picks it), so the short delay only matters for a real blur away.
    bbChoreSearchEl.addEventListener("blur", () =>
      window.setTimeout(hideChoreResults, 150),
    );
  }
  if (bbChoreResultsEl) {
    // mousedown, not click: it fires before the input's blur, so the pick lands
    // instead of the dropdown closing out from under the tap.
    bbChoreResultsEl.addEventListener("mousedown", (e) => {
      const opt = e.target.closest("[data-bb-chore-option]");
      if (opt?._option) {
        e.preventDefault();
        chooseChore(opt._option);
      }
    });
  }

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
    drainFailed().then(resync);
  });

  paint();
  maybeYawn();

  return {
    // A chores broadcast landed. The envelope says only that something
    // changed and who did it, not what it changed to, so this asks — the same
    // thing /chores/today does with the same signal.
    onChoresChanged() {
      resync();
    },

    // The socket came back. Anything that failed while it was down is worth
    // one more go now, and it has to finish BEFORE the resync: run together,
    // the resync can land first and paint the server's old state over the
    // prediction the retry was in the middle of confirming.
    async onReconnect() {
      await drainFailed();
      await resync();
    },

    resync,
  };
}
