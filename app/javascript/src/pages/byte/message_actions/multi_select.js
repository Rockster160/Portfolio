// Renders any ByteAction where multi_select == true as a checkbox list
// with a submit button and per-row status glyphs. Generic — used by
// Buddy proposals today, any future multi-select ask tomorrow.
//
// The action ships onto the message's metadata as `buttons: [{ id, label,
// status, ... }]`; we mount into `.byte-msg-actions` (which the existing
// message renderer already leaves as a hook slot per message).
//
// Submits to the existing /byte/actions/:request_id/respond endpoint via
// apiCall — same wire the single-select renderer uses.

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
  executed:  "✓",
  cancelled: "·",
  failed:    "✗",
  partial:   "~",
};

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
  const isDecided = meta.action_state === "decided";

  container.innerHTML = "";
  container.classList.add("byte-msg-multi-select");

  buttons.forEach((btn) => {
    const row = document.createElement("label");
    row.className = "byte-msg-action-row";
    row.dataset.status = btn.status || "pending";
    row.dataset.buttonId = btn.id;
    row.dataset.toolName = btn.tool_name || "";

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = btn.id;
    cb.disabled = isDecided;
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

  if (!isDecided) {
    const submit = document.createElement("button");
    submit.type = "button";
    submit.className = "byte-msg-multi-select-submit";
    submit.textContent = "Confirm";
    submit.addEventListener("click", () => submitDecision(container, requestId, submit));
    container.appendChild(submit);
  }

  return true;
}

async function submitDecision(container, requestId, submitBtn) {
  const checkedIds = Array.from(container.querySelectorAll('input[type="checkbox"]:checked'))
    .map((cb) => Number(cb.value));

  submitBtn.disabled = true;
  submitBtn.textContent = "Working...";

  try {
    await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/respond`, "POST", {
      value: checkedIds,
    });
    // The server broadcast will re-render the message with updated statuses,
    // so we don't touch the DOM here — no double-application.
  } catch (e) {
    submitBtn.disabled = false;
    submitBtn.textContent = "Retry";
    console.warn("[byte] multi-select submit failed", e);
  }
}
