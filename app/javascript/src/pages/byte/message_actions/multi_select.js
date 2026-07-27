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
};

// Statuses that mean the row has been acted on — checkbox stays checked
// and locked. Everything else (pending) is still live and re-triggerable.
const RESOLVED_STATUSES = new Set(["executed", "partial", "failed"]);

// Per-tool action-verb prefix so each checkbox row makes it clear WHAT
// tapping the box will do. Without this the label is just "Water 24oz"
// and the user can't tell if it'll log an event, complete a chore, or
// add to a list. Short + colored to read as metadata, not part of the
// item name.
const ACTION_KIND_LABELS = {
  complete_chore:        "Complete",
  create_chore:          "Add chore",
  edit_chore:            "Edit chore",
  undo_chore_completion: "Undo",
  add_agenda_item:       "Schedule",
  edit_agenda_item:      "Edit event",
  add_list_item:         "Add to list",
  edit_list_item:        "Edit item",
  remove_list_item:      "Remove",
  log_event:             "Log",
  edit_event:            "Edit log",
  delete_event:          "Delete log",
  schedule_reminder:     "Remind",
  cancel_reminder:       "Cancel reminder",
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

  container.innerHTML = "";
  container.classList.add("byte-msg-multi-select");

  buttons.forEach((btn) => {
    const status = btn.status || "pending";
    // A row is "resolved" once it has been acted on. Resolved rows stay
    // checked and locked so the checkmark persists (the user's tap is a
    // permanent record, not something that vanishes on execution). Only
    // still-pending rows are live and re-triggerable.
    const resolved = RESOLVED_STATUSES.has(status);

    const row = document.createElement("label");
    row.className = "byte-msg-action-row";
    row.dataset.status = status;
    row.dataset.buttonId = btn.id;
    row.dataset.toolName = btn.tool_name || "";

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = btn.id;
    cb.checked = resolved;      // retain the check for anything already acted on
    cb.disabled = resolved;     // can't un-do a completed row from here
    // Checking a pending row IS the confirmation — fire it immediately.
    if (!resolved) {
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

    const glyph = STATUS_GLYPHS[btn.status || "pending"];
    if (glyph) {
      const g = document.createElement("span");
      g.className = "byte-msg-action-glyph";
      g.textContent = glyph;
      row.appendChild(g);
    }

    if (btn.error_message) {
      const err = document.createElement("span");
      err.className = "byte-msg-action-error";
      err.textContent = btn.error_message;
      row.appendChild(err);
    }

    container.appendChild(row);
  });

  return true;
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
    // Roll back the optimistic lock so the user can retry.
    changedCb.checked = false;
    changedCb.disabled = false;
    if (row) row.dataset.status = "pending";
    console.warn("[byte] proposal trigger failed", e);
  }
}
