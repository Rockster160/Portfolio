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
  pending:   "",
  working:   "…",
  executed:  "✓",
  cancelled: "·",
  failed:    "✗",
  partial:   "~",
  undone:    "↩",
  expired:   "⌛",
};

// Statuses that mean the row has been acted on — checkbox stays checked
// and locked. Everything else (pending) is still live and re-triggerable.
const RESOLVED_STATUSES = new Set(["executed", "partial", "failed"]);

// Per-tool action-verb prefix so each checkbox row makes it clear WHAT
// tapping the box will do. Without this the label is just "Water 24oz"
// and the user can't tell if it'll log an event, complete a chore, or
// add to a list. Short + colored to read as metadata, not part of the
// item name.
// Verb + what it acts on, so a generic "Add" / "Edit" / "Remove" never
// stands alone. "Log" and "Complete" are specific enough as-is.
const ACTION_KIND_LABELS = {
  complete_chore:        "Complete",
  create_chore:          "Add Chore",
  edit_chore:            "Edit Chore",
  undo_chore_completion: "Undo",
  undo:                  "Undo",
  add_agenda_item:       "Add Event",
  edit_agenda_item:      "Edit Event",
  add_list_item:         "Add to List",
  edit_list_item:        "Edit List Item",
  remove_list_item:      "Remove from List",
  log_event:             "Log",
  edit_event:            "Edit Log",
  delete_event:          "Delete Log",
  schedule_reminder:     "Remind",
  cancel_reminder:       "Cancel Reminder",
};

// Render (or re-render) into a container element. Container is expected
// to sit inside the message bubble, cleared each call so per-row state
// updates don't leave stale nodes.
export function renderMultiSelect(container, message) {
  const meta = message?.metadata || {};
  if (!meta.multi_select) return false;
  const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
  if (buttons.length === 0) return false;

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
    const status = btn.status || "pending";
    // A row is "resolved" once it has been acted on. Resolved rows stay
    // checked and locked so the checkmark persists (the user's tap is a
    // permanent record, not something that vanishes on execution). Only
    // still-pending rows are live and re-triggerable.
    const resolved = RESOLVED_STATUSES.has(status);
    // A Level-2 row ran the instant Buddy proposed it, so it arrives already
    // executed AND undoable: shown pre-checked, and UNchecking it walks the
    // action back. Everything else that's resolved stays locked.
    const undoable = status === "executed" && !!btn.undoable;
    const undone = status === "undone";
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
    cb.checked = resolved && status !== "failed";
    // Resolved/undone rows are locked; only a still-live pending row (or an
    // undoable executed one) stays toggleable. An expired row stays tappable —
    // but tapping REISSUES it (see below) rather than trying to run the stale one.
    cb.disabled = (resolved || undone) && !undoable;
    if (rowExpired) {
      // Tapping a stale row reissues it as a fresh checklist — no re-typing.
      cb.addEventListener("change", () => {
        if (cb.checked) redoExpired(container, requestId, cb);
      });
    } else if (undoable) {
      // Unchecking a pre-checked Level-2 row undoes it.
      cb.addEventListener("change", () => {
        if (!cb.checked) undoRow(container, requestId, cb);
      });
    } else if (!resolved && !undone && !confirmMode) {
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
    const kindLabel = ACTION_KIND_LABELS[btn.tool_name];
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

  try {
    await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/respond`, "POST", {
      value: checkedIds,
    });
    // Server broadcast re-renders each row with its executed/failed status,
    // so we don't touch the DOM here — no double-application.
  } catch (e) {
    // Roll back the optimistic lock so the user can retry — but SAY so. A bare
    // silent uncheck reads like nothing happened (or a bug); a short note tells
    // them it didn't go through and re-tapping retries.
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
