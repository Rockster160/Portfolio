// Renders any ByteAction where multi_select == true as a checkbox list
// with per-row status glyphs. Generic — used by Buddy proposals today,
// any future multi-select ask tomorrow.
//
// The action ships onto the message's metadata as `buttons: [{ id, label,
// status, ... }]`; we mount into `.byte-msg-actions` (which the existing
// message renderer already leaves as a hook slot per message).
//
// Interaction model: there is NO confirm button. Checking a row triggers
// THAT proposal immediately — the check is the confirmation. Each POST to
// /byte/actions/:request_id/respond carries the full set of checked ids;
// the server executes any that are still pending and leaves the rest
// tappable (incremental, not all-or-nothing). Once a row has executed it
// stays checked and locked; the server broadcast re-renders it with its
// ✓ status. A row the user never checks simply expires with the action.

// Small inline fetch — the shared apiCall lives inside conversations.js
// as a private helper and there's no v1 reason to lift it. Duplication
// is small and self-contained.
async function apiCall(url, method, body) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrf = csrfMeta ? csrfMeta.getAttribute("content") : "";
  const options = {
    method,
    credentials: "same-origin",
    headers: {
      "Content-Type":  "application/json",
      "Accept":        "application/json",
      "X-CSRF-Token":  csrf,
    },
  };
  if (body != null) options.body = JSON.stringify(body);
  const res = await fetch(url, options);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json().catch(() => ({}));
}

const STATUS_GLYPHS = {
  pending:    "",
  working:    "…",
  executed:   "✓",
  cancelled:  "·",
  failed:     "✗",
  partial:    "~",
  undone:     "↩",
  superseded: "↻",
  expired:    "⌛",
};

// Statuses that mean the row has been acted on — checkbox stays checked
// and locked. Everything else (pending) is still live and re-triggerable.
const RESOLVED_STATUSES = new Set(["executed", "partial", "failed"]);

// Rows the person has tapped whose outcome hasn't come back yet, as
// requestId -> Map(buttonId -> tapped at).
//
// The server runs a checked row in a JOB and answers the POST immediately, so
// the response — and any broadcast triggered by an EARLIER tap — still reports
// this row as pending. A repaint is destructive (the container is rebuilt from
// `buttons` every time), so checking two rows in a row used to unpick the
// second one: tap A, tap B, A's broadcast lands saying "A executed, B pending",
// B renders unchecked, and a moment later B's own broadcast flips it back. The
// flicker was the render being authoritative about a row whose answer was
// simply still in the post.
//
// Module-level so it survives repaints, and keyed by request so two checklists
// in one thread can't tread on each other.
const IN_FLIGHT = new Map();

// A tap whose job never reported back — the worker died, the deploy landed
// mid-flight. Long enough that a slow tool (a Mac round trip) still counts as
// in flight, short enough that the row doesn't stay locked forever.
const IN_FLIGHT_TTL_MS = 120000;

function inFlightFor(requestId) {
  if (!IN_FLIGHT.has(requestId)) IN_FLIGHT.set(requestId, new Map());
  return IN_FLIGHT.get(requestId);
}

function markInFlight(requestId, id) {
  inFlightFor(requestId).set(Number(id), Date.now());
}

function clearInFlight(requestId, id) {
  inFlightFor(requestId).delete(Number(id));
}

// Whether this row is still waiting on its own answer. Anything the server has
// since resolved, or that has sat here past the TTL, is dropped — so the map
// empties itself and nothing has to remember to tidy it.
function stillAwaiting(requestId, id, serverStatus) {
  const pending = inFlightFor(requestId);
  const at = pending.get(Number(id));
  if (at == null) return false;
  if (serverStatus !== "pending" || Date.now() - at > IN_FLIGHT_TTL_MS) {
    pending.delete(Number(id));
    return false;
  }
  return true;
}

// An agenda item is a task, an event, or a trigger, and they are not the same
// thing to the person reading the row — a to-do called an "Event" is simply
// wrong, and it's the word that tells them whether the thing will occupy a span
// of their day. Both agenda tools put the item's kind on the payload
// (add_agenda_item takes it as an argument; edit_agenda_item resolves it off the
// record, since editing one doesn't change what it is).
const AGENDA_KINDS = { task: "Task", trigger: "Trigger" };

function agendaKind(verb, payload) {
  return `${verb} Agenda ${AGENDA_KINDS[payload?.kind] || "Event"}`;
}

// Per-tool chip so each checkbox row makes it clear WHAT tapping the box will
// do. Without it the label is just "Water 24oz" and there's no telling whether
// that logs an event, completes a chore, or lands on a list.
//
// Names the THING and where it lives, rather than the verb that runs. "Add
// Task" said what the tool was called; "New Agenda Task" says what will exist
// afterwards, which is the question someone reading a confirmation is actually
// asking. The qualifier is load-bearing too — an agenda Event and a logged
// event are different things that used to read as "Add Event" and "Log".
//
// A value may be a function of the payload when one tool covers more than one
// kind of thing.
const ACTION_KIND_LABELS = {
  complete_chore:        "Complete Chore",
  create_chore:          "New Chore",
  edit_chore:            "Edit Chore",
  undo_chore_completion: "Undo Chore",
  undo:                  "Undo",
  add_agenda_item:       (p) => agendaKind("New", p),
  edit_agenda_item:      (p) => agendaKind("Edit", p),
  add_list_item:         "New List Item",
  edit_list_item:        "Edit List Item",
  remove_list_item:      "Remove List Item",
  log_event:             "New Logged Event",
  edit_event:            "Edit Logged Event",
  delete_event:          "Delete Logged Event",
  schedule_reminder:     "New Reminder",
  cancel_reminder:       "Cancel Reminder",
};

// The chip above a checklist row, or null for a tool that doesn't get one.
// Exported so it can be tested without a DOM.
export function actionKindLabel(toolName, payload) {
  const entry = ACTION_KIND_LABELS[toolName];
  return typeof entry === "function" ? entry(payload || {}) : entry || null;
}

// Render (or re-render) into a container element. Container is expected
// to sit inside the message bubble, cleared each call so per-row state
// updates don't leave stale nodes.
export function renderMultiSelect(container, message) {
  const meta = message?.metadata || {};
  if (!meta.multi_select) return false;
  const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
  if (buttons.length === 0) return false;

  // "manage" = a live management list (the reminders list): each row is an
  // existing thing with a trailing × to remove it (not a checkbox to run a
  // proposed action). Separate layout so the two never blur together.
  if (meta.select_mode === "manage") return renderManageList(container, message);

  const requestId = meta.action_request_id;
  // "confirm" = pick-any with a Send button (a relayed select-all question);
  // otherwise each check fires immediately (Buddy proposals, pick-one).
  const confirmMode = meta.select_mode === "confirm";
  // A stale checklist can't run — the server rejects the tap. Detect expiry
  // here so we render those rows disabled instead of letting the person tap
  // into a silent nothing.
  const expiresAt = meta.action_expires_at ? Date.parse(meta.action_expires_at) : NaN;
  const expired = Number.isFinite(expiresAt) && Date.now() > expiresAt;

  container.innerHTML = "";
  container.classList.add("byte-msg-multi-select");

  buttons.forEach((btn) => {
    const serverStatus = btn.status || "pending";
    // Their tap outranks a repaint that hasn't heard about it yet. See
    // IN_FLIGHT: the executor is a job, so "pending" here can simply mean the
    // answer is still on its way.
    const awaiting = stillAwaiting(requestId, btn.id, serverStatus);
    const status = awaiting ? "working" : serverStatus;
    // A row is "resolved" once it has been acted on. Resolved rows stay
    // checked and locked so the checkmark persists (the user's tap is a
    // permanent record, not something that vanishes on execution). Only
    // still-pending rows are live and re-triggerable.
    const resolved = RESOLVED_STATUSES.has(status);
    // Any row that ran AND came back with a way to reverse itself: shown
    // checked, and UNchecking it walks the action back. A Level-2 row arrives
    // this way (it ran the instant Buddy proposed it); a tapped Level-3 row
    // becomes it once it executes, which is what gives `undo` a way back.
    // Everything else that's resolved stays locked.
    const undoable = status === "executed" && !!btn.undoable;
    const undone = status === "undone";
    // A newer ask replaced this one, so it's finished with either way: locked,
    // never re-triggerable, and never undoable — the row that replaced it owns
    // the record now, so walking this one back would delete what that one did.
    // `superseded_from` keeps whether it had actually RUN before being replaced,
    // so an executed row still reads as done rather than as never-happened.
    const superseded = status === "superseded";
    // A still-pending row on an expired action can't be run.
    const rowExpired = expired && status === "pending";
    const effectiveStatus = rowExpired ? "expired" : status;

    const row = document.createElement("label");
    row.className = "byte-msg-action-row";
    row.dataset.status = effectiveStatus;
    row.dataset.buttonId = btn.id;
    row.dataset.toolName = btn.tool_name || "";

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = btn.id;
    // executed/partial read as "on"; failed + undone + expired read as "off".
    // A row awaiting its answer stays on, because they put it there.
    cb.checked = awaiting
      ? true
      : superseded
        ? btn.superseded_from === "executed"
        : resolved && status !== "failed";
    // Resolved/undone/superseded rows are locked; only a still-live pending row
    // (or an undoable executed one) stays toggleable. An expired row stays
    // tappable — but tapping REISSUES it (see below) rather than running the
    // stale one. One mid-flight is locked so a second tap can't double-fire it.
    cb.disabled = awaiting || superseded || ((resolved || undone) && !undoable);
    if (awaiting) {
      // Nothing to bind: it's already doing the thing.
    } else if (rowExpired) {
      // Tapping a stale row reissues it as a fresh checklist — no re-typing.
      cb.addEventListener("change", () => {
        if (cb.checked) redoExpired(container, requestId, cb);
      });
    } else if (undoable) {
      // Unchecking a pre-checked Level-2 row undoes it.
      cb.addEventListener("change", () => {
        if (!cb.checked) undoRow(container, requestId, cb);
      });
    } else if (!resolved && !undone && !superseded && !confirmMode) {
      // Checking a pending row IS the confirmation — fire it immediately.
      // Exception: confirm mode collects a set and submits once via the Send
      // button below, so checking a box there only toggles local state.
      cb.addEventListener("change", () => {
        if (cb.checked) triggerChecked(container, requestId, cb);
      });
    }
    row.appendChild(cb);

    // Body wraps [tiny-chip-on-top, label-below] so the action-kind
    // sits ABOVE the item text instead of eating horizontal space
    // beside it. The chip is intentionally tiny (~9px) since it's
    // secondary metadata, not the primary content.
    const body = document.createElement("span");
    body.className = "byte-msg-action-body";
    const kindLabel = actionKindLabel(btn.tool_name, btn.payload);
    if (kindLabel) {
      const kind = document.createElement("span");
      kind.className = "byte-msg-action-kind";
      kind.textContent = kindLabel;
      body.appendChild(kind);
    }
    const label = document.createElement("span");
    label.className = "byte-msg-action-label";
    label.textContent = btn.label || `#${btn.id}`;
    body.appendChild(label);
    if (btn.sublabel) {
      const sub = document.createElement("span");
      sub.className = "byte-msg-action-sublabel";
      sub.textContent = btn.sublabel;
      body.appendChild(sub);
    }
    row.appendChild(body);

    const glyph = STATUS_GLYPHS[effectiveStatus];
    if (glyph) {
      const g = document.createElement("span");
      g.className = "byte-msg-action-glyph";
      g.textContent = glyph;
      row.appendChild(g);
    }

    // A failed row is highlighted red (CSS) with the error inline AND as a
    // hover tooltip over the whole row.
    if (btn.error_message) {
      row.title = btn.error_message;
      const err = document.createElement("span");
      err.className = "byte-msg-action-error";
      err.textContent = btn.error_message;
      row.appendChild(err);
    }

    // Replaced: say so, so a struck-through row doesn't read as a failure.
    if (superseded) {
      row.title = "A newer version of this replaced it.";
      const note = document.createElement("span");
      note.className = "byte-msg-action-expired";
      note.textContent = "Replaced by a newer one.";
      row.appendChild(note);
    }

    // Expired: say so, and that tapping brings it back fresh.
    if (rowExpired) {
      row.title = "This expired — tap to get a fresh one.";
      const note = document.createElement("span");
      note.className = "byte-msg-action-expired";
      note.textContent = "Expired — tap to redo.";
      row.appendChild(note);
    }

    container.appendChild(row);
  });

  // Confirm mode: one Send button submits the whole checked set at once, so
  // the recipient can pick several options before answering. Only shown while
  // rows remain live.
  if (confirmMode) {
    const anyLive = buttons.some(
      (b) => !RESOLVED_STATUSES.has(b.status || "pending"),
    );
    if (anyLive) {
      const submit = document.createElement("button");
      submit.type = "button";
      submit.className = "byte-msg-multi-select-submit basic";
      submit.textContent = "Send";
      submit.addEventListener("click", () =>
        submitChecked(container, requestId, submit),
      );
      container.appendChild(submit);
    }
  }

  return true;
}

// Confirm-mode submit: send every checked row's id in one POST. The server
// records the full set as the answer, marks the rows executed/cancelled, and
// broadcasts the settled checklist back. Optimistically locks the controls so
// a double-tap can't double-submit; rolls back on failure.
async function submitChecked(container, requestId, button) {
  const checkedIds = Array.from(
    container.querySelectorAll('input[type="checkbox"]:checked'),
  ).map((cb) => Number(cb.value));
  if (checkedIds.length === 0) return;

  button.disabled = true;
  const boxes = container.querySelectorAll('input[type="checkbox"]');
  boxes.forEach((cb) => {
    cb.disabled = true;
  });

  try {
    await apiCall(
      `/byte/actions/${encodeURIComponent(requestId)}/respond`,
      "POST",
      { value: checkedIds },
    );
    // Server broadcast re-renders the settled rows; nothing to touch here.
  } catch (e) {
    button.disabled = false;
    boxes.forEach((cb) => {
      const row = cb.closest(".byte-msg-action-row");
      if (!row || !RESOLVED_STATUSES.has(row.dataset.status)) cb.disabled = false;
    });
    console.warn("[byte] relay answer submit failed", e);
  }
}

// Tapping an EXPIRED row reissues it. POSTs { redo: id }; the server rebuilds
// the proposal as a fresh, tappable checklist on a NEW message. This stale row
// stays put (its checkbox just acts as the button), so we roll it back.
async function redoExpired(container, requestId, cb) {
  const id = Number(cb.value);
  cb.disabled = true;
  const row = cb.closest(".byte-msg-action-row");
  if (row) row.dataset.status = "working";
  try {
    await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/respond`, "POST", {
      redo: id,
    });
    // Fresh checklist arrives as its own message; leave this one marked expired.
  } catch (e) {
    console.warn("[byte] proposal reissue failed", e);
  } finally {
    cb.checked = false;
    cb.disabled = false;
    if (row) row.dataset.status = "expired";
  }
}

// Undo a pre-checked Level-2 row (the person unchecked it). POSTs { undo: id };
// the server reverses the action, marks the row "undone", and broadcasts the
// re-rendered checklist. Optimistically lock the box; roll back on failure.
async function undoRow(container, requestId, cb) {
  const id = Number(cb.value);
  cb.disabled = true;
  const row = cb.closest(".byte-msg-action-row");
  if (row) row.dataset.status = "working";
  try {
    await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/respond`, "POST", {
      undo: id,
    });
    // Server broadcast re-renders the row as "undone" — nothing to touch here.
  } catch (e) {
    cb.checked = true;
    cb.disabled = false;
    if (row) row.dataset.status = "executed";
    console.warn("[byte] proposal undo failed", e);
  }
}

// Management-list layout (the reminders list). Each row shows a glyph + label
// + when, with a trailing × to remove it. A removed row strikes through and
// swaps the × for an Undo. Removal/restore POST to the SAME respond endpoint
// with { cancel: id } / { undo: id }; the server re-broadcasts the list, which
// re-renders this whole block, so success needs no local DOM patching.
function renderManageList(container, message) {
  const meta = message?.metadata || {};
  const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
  const requestId = meta.action_request_id;

  container.innerHTML = "";
  container.classList.add("byte-msg-manage-list");

  buttons.forEach((btn) => {
    const status = btn.status || "active";
    const cancelled = status === "cancelled";
    const working = status === "working";

    const row = document.createElement("div");
    row.className = "byte-msg-manage-row";
    row.dataset.status = status;
    row.dataset.buttonId = btn.id;

    if (btn.glyph) {
      const g = document.createElement("span");
      g.className = "byte-msg-manage-glyph";
      g.textContent = btn.glyph;
      row.appendChild(g);
    }

    const body = document.createElement("span");
    body.className = "byte-msg-manage-body";
    const label = document.createElement("span");
    label.className = "byte-msg-manage-label";
    label.textContent = btn.label || `#${btn.id}`;
    body.appendChild(label);
    if (btn.sublabel) {
      const sub = document.createElement("span");
      sub.className = "byte-msg-manage-sublabel";
      sub.textContent = btn.sublabel;
      body.appendChild(sub);
    }
    row.appendChild(body);

    const ctrl = document.createElement("button");
    ctrl.type = "button";
    ctrl.className = "byte-msg-manage-ctrl";
    ctrl.disabled = working;
    if (cancelled) {
      ctrl.classList.add("is-undo");
      ctrl.textContent = "Undo";
      ctrl.setAttribute("aria-label", `Restore ${btn.label || "reminder"}`);
      ctrl.addEventListener("click", () => manageAction(container, requestId, btn.id, "undo", ctrl));
    } else {
      ctrl.classList.add("is-remove");
      ctrl.textContent = "×";
      ctrl.setAttribute("aria-label", `Remove ${btn.label || "reminder"}`);
      ctrl.addEventListener("click", () => manageAction(container, requestId, btn.id, "cancel", ctrl));
    }
    row.appendChild(ctrl);

    container.appendChild(row);
  });

  return true;
}

// Remove (cancel) or restore (undo) one management-list row. Optimistically
// marks the row "working"; the server broadcast re-renders the settled list.
// On failure, roll the row back to its prior state so the control is live again.
async function manageAction(container, requestId, id, kind, ctrl) {
  const row = ctrl.closest(".byte-msg-manage-row");
  const prevStatus = row ? row.dataset.status : null;
  ctrl.disabled = true;
  if (row) row.dataset.status = "working";
  try {
    await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/respond`, "POST", {
      [kind]: Number(id),
    });
    // Broadcast re-renders the list; nothing to touch here.
  } catch (e) {
    ctrl.disabled = false;
    if (row && prevStatus) row.dataset.status = prevStatus;
    console.warn("[byte] reminder manage failed", e);
  }
}

// Fire the currently-checked rows. Sends the FULL checked set every time
// (idempotent server-side: already-executed rows are skipped), so the
// backend runs the newly-checked one and leaves untouched rows pending and
// still tappable. Optimistically lock the row that triggered this so a
// double-tap can't double-fire; the server broadcast re-renders with the
// real ✓ / ✗ status a beat later.
async function triggerChecked(container, requestId, changedCb) {
  const checkedIds = Array.from(container.querySelectorAll('input[type="checkbox"]:checked'))
    .map((cb) => Number(cb.value));

  changedCb.disabled = true;
  const row = changedCb.closest(".byte-msg-action-row");
  if (row) row.dataset.status = "working";
  // Held across repaints, not just on this node — the node itself is about to
  // be thrown away and rebuilt by the next broadcast.
  markInFlight(requestId, changedCb.value);

  try {
    await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/respond`, "POST", {
      value: checkedIds,
    });
    // Server broadcast re-renders each row with its executed/failed status,
    // so we don't touch the DOM here — no double-application. The row stays
    // marked in-flight until that arrives, since the executor is a job and the
    // response we just got still says "pending".
  } catch (e) {
    // Roll back the optimistic lock so the user can retry — but SAY so. A bare
    // silent uncheck reads like nothing happened (or a bug); a short note tells
    // them it didn't go through and re-tapping retries.
    clearInFlight(requestId, changedCb.value);
    changedCb.checked = false;
    changedCb.disabled = false;
    if (row) {
      row.dataset.status = "pending";
      const msg = `Couldn't do that just now${e?.message ? ` (${e.message})` : ""} — tap to try again.`;
      row.title = msg; // tooltip over the row
      row.dataset.error = "true"; // red highlight (CSS), still tappable
      let err = row.querySelector(".byte-msg-action-error");
      if (!err) {
        err = document.createElement("span");
        err.className = "byte-msg-action-error";
        row.appendChild(err);
      }
      err.textContent = "Couldn't do that just now — tap to try again.";
    }
    console.warn("[byte] proposal trigger failed", e);
  }
}
