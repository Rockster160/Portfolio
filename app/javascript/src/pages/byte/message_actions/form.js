// An editable form inside a message bubble — the third action shape, after the
// proposal checklist (multi_select.js) and the manage list.
//
// Buddy fills one in with its best guess and the person corrects whatever is
// wrong before sending, which is what makes guessing safe. That also makes this
// the first thing in the thread holding LOCAL state the server doesn't know
// about, and both hazards below come from exactly that:
//
//   1. Repaints are destructive and frequent. paintMessageNode rewrites the
//      body, and refetchHistory repaints every message on channel connect and
//      on every visibilitychange -> visible. Backgrounding the PWA mid-edit
//      would otherwise wipe a half-filled form. Every edit is mirrored into
//      DRAFTS, and a rebuild re-seeds from there.
//   2. A rebuild while someone is typing moves the caret. So a repaint is
//      skipped outright whenever focus is inside this container.
//
// Field types mirror shared/_dynamic_form_fields, since the app's own Prompt
// pages are the first thing this renders.

// requestId -> { key: value }. Module-level so it survives any number of
// repaints, and deliberately not localStorage: a draft is only interesting
// while the thread is open, and a stale one resurfacing on another device would
// be worse than none.
const DRAFTS = new Map();

const INPUT_TYPES = {
  text: "text",
  number: "number",
  date: "date",
  datetime: "datetime-local",
  time: "time",
  color: "color",
};

async function apiCall(url, method, body) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrf = csrfMeta ? csrfMeta.getAttribute("content") : "";
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-CSRF-Token": csrf,
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}`);
    err.errors = json.errors;
    throw err;
  }
  return json;
}

function draftFor(requestId) {
  if (!DRAFTS.has(requestId)) DRAFTS.set(requestId, {});
  return DRAFTS.get(requestId);
}

export function renderForm(container, message) {
  const meta = message?.metadata || {};
  const form = meta.form;
  if (!form || !Array.isArray(form.fields)) return false;

  const requestId = meta.action_request_id;
  // Never rebuild under someone's cursor. Whatever triggered this repaint has
  // nothing in it worth more than the value being typed.
  if (container.contains(document.activeElement)) return true;

  const submitted = form.status === "submitted";
  // A corrected version of this form landed further down the thread, so this
  // one is no longer a question anyone needs to answer. The server already
  // refuses the submit; lock it here so it doesn't look live.
  const superseded = form.status === "superseded";
  const expiresAt = meta.action_expires_at
    ? Date.parse(meta.action_expires_at)
    : NaN;
  const expired =
    !submitted &&
    !superseded &&
    Number.isFinite(expiresAt) &&
    Date.now() > expiresAt;
  const locked = submitted || superseded || expired;
  // A settled form shows what was actually recorded, never a local draft. The
  // answer may have been given somewhere else entirely — the prompt's own page
  // — in which case a half-typed guess sitting here is pure fiction.
  if (locked) DRAFTS.delete(requestId);
  const draft = locked ? {} : draftFor(requestId);

  container.innerHTML = "";
  container.className = "byte-msg-form";
  container.dataset.status = submitted
    ? "submitted"
    : superseded
      ? "superseded"
      : expired
        ? "expired"
        : "pending";

  form.fields.forEach((field) => {
    if (field.type === "hidden") return;
    const row = buildRow(field, { draft, locked });
    if (row) container.appendChild(row);
  });

  const errorEl = document.createElement("div");
  errorEl.className = "byte-msg-form-errors";
  errorEl.hidden = true;
  container.appendChild(errorEl);

  const footer = document.createElement("div");
  footer.className = "byte-msg-form-footer";

  if (locked) {
    const note = document.createElement("span");
    note.className = "byte-msg-form-receipt";
    note.textContent = submitted
      ? form.receipt || "Sent ✓"
      : superseded
        ? "Replaced by a newer one below."
        : "Expired — ask me again and I'll rebuild it.";
    footer.appendChild(note);
  } else {
    footerActions(form).forEach((spec) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "byte-msg-form-btn basic";
      button.dataset.style = spec.style || "plain";
      button.dataset.key = spec.key;
      button.textContent = spec.label;
      button.addEventListener("click", () =>
        submitForm(container, requestId, button, errorEl, spec),
      );
      footer.appendChild(button);
    });
  }

  container.appendChild(footer);
  return true;
}

// The footer buttons, in the order the server put them: alternates first, the
// submit last so the primary sits on the right. Only ONE of them sends the
// field values — a Skip runs its own thing and never reads the boxes.
//
// The fallback is for a form posted before actions existed, which is still
// sitting live in a thread and carries only `submit`.
function footerActions(form) {
  if (Array.isArray(form.actions) && form.actions.length) return form.actions;

  return [
    { key: "submit", label: form.submit || "Send", style: "primary", sends: true },
  ];
}

// One labelled row. Not a <label> wrapper like the checklist uses — that makes
// the whole row activate the control, which fights an input for the tap.
function buildRow(field, { draft, locked }) {
  const row = document.createElement("div");
  row.className = "byte-msg-form-row";
  row.dataset.key = field.key;
  row.dataset.type = field.type;

  const label = document.createElement("span");
  label.className = "byte-msg-form-label";
  label.textContent = field.label || field.key;
  row.appendChild(label);

  const seeded = Object.prototype.hasOwnProperty.call(draft, field.key)
    ? draft[field.key]
    : field.value;
  const control = buildControl(field, seeded, locked);
  if (!control) return null;
  row.appendChild(control);

  if (field.hint) {
    const hint = document.createElement("span");
    hint.className = "byte-msg-form-hint";
    hint.textContent = field.hint;
    row.appendChild(hint);
  }

  // Mirror every edit into the draft so a repaint can put it back. Both events:
  // `input` covers typing and dragging, `change` covers select and checkbox.
  const remember = () => {
    draft[field.key] = readRow(row);
  };
  row.addEventListener("input", remember);
  row.addEventListener("change", remember);

  return row;
}

function buildControl(field, value, locked) {
  const type = field.type;

  if (type === "choices") {
    const wrap = document.createElement("div");
    wrap.className = "byte-msg-form-choices";
    const picked = new Set(
      (Array.isArray(value) ? value : String(value ?? "").split(","))
        .map((v) => String(v).trim())
        .filter(Boolean),
    );
    (field.choices || []).forEach((choice) => {
      const opt = document.createElement("label");
      opt.className = "byte-msg-form-choice";
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.value = choice;
      cb.checked = picked.has(choice);
      cb.disabled = locked;
      opt.appendChild(cb);
      const text = document.createElement("span");
      text.textContent = choice;
      opt.appendChild(text);
      wrap.appendChild(opt);
    });
    return wrap;
  }

  if (type === "select") {
    const sel = document.createElement("select");
    sel.className = "byte-msg-form-input";
    sel.disabled = locked;
    // A required select has no "nothing" to pick, so it doesn't offer one. The
    // prompt page renders these with no blank option either, which is why the
    // first choice is what's showing when a "Who did it?" opens there — a
    // placeholder here made the same form open on "—" and read as unanswered.
    if (!field.required) {
      const blank = document.createElement("option");
      blank.value = "";
      blank.textContent = "—";
      sel.appendChild(blank);
    }
    (field.choices || []).forEach((choice) => {
      const opt = document.createElement("option");
      opt.value = choice;
      opt.textContent = choice;
      sel.appendChild(opt);
    });
    // Assigning "" to a select with no blank option selects NOTHING (index -1)
    // and draws an empty box, so an unfilled required one is left alone at the
    // browser's default: the first choice.
    const wanted = value == null ? "" : String(value);
    if (wanted !== "") {
      sel.value = wanted;
    } else if (!field.required) {
      sel.value = "";
    }
    return sel;
  }

  if (type === "checkbox") {
    const wrap = document.createElement("div");
    wrap.className = "byte-msg-form-choices";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.className = "byte-msg-form-check";
    cb.checked = String(value) === "true";
    cb.disabled = locked;
    wrap.appendChild(cb);
    return wrap;
  }

  if (type === "scale") {
    const wrap = document.createElement("div");
    wrap.className = "byte-msg-form-scale";
    const range = document.createElement("input");
    range.type = "range";
    range.min = field.min ?? 0;
    range.max = field.max ?? 100;
    range.value = value == null || value === "" ? range.min : String(value);
    range.disabled = locked;
    const out = document.createElement("span");
    out.className = "byte-msg-form-scale-value";
    out.textContent = range.value;
    range.addEventListener("input", () => {
      out.textContent = range.value;
    });
    wrap.appendChild(range);
    wrap.appendChild(out);
    return wrap;
  }

  if (type === "textarea") {
    const ta = document.createElement("textarea");
    ta.className = "byte-msg-form-input";
    ta.rows = 2;
    ta.value = value == null ? "" : String(value);
    ta.disabled = locked;
    return ta;
  }

  const input = document.createElement("input");
  input.type = INPUT_TYPES[type] || "text";
  input.className = "byte-msg-form-input";
  input.value = value == null ? "" : String(value);
  input.disabled = locked;
  if (field.min != null) input.min = field.min;
  if (field.max != null) input.max = field.max;
  if (field.step != null) input.step = field.step;
  return input;
}

// What one row currently holds, in the shape the server expects.
function readRow(row) {
  const type = row.dataset.type;

  if (type === "choices") {
    return Array.from(
      row.querySelectorAll('input[type="checkbox"]:checked'),
    ).map((cb) => cb.value);
  }
  if (type === "checkbox") {
    return row.querySelector('input[type="checkbox"]')?.checked
      ? "true"
      : "false";
  }
  return row.querySelector("input, select, textarea")?.value ?? "";
}

function readAll(container) {
  const values = {};
  container.querySelectorAll(".byte-msg-form-row").forEach((row) => {
    values[row.dataset.key] = readRow(row);
  });
  return values;
}

async function submitForm(container, requestId, button, errorEl, spec) {
  // Every button goes down together: they all resolve the same form, so one in
  // flight has to lock out the rest rather than only itself. Skipping a prompt
  // mid-send would otherwise race the answer.
  const buttons = Array.from(container.querySelectorAll(".byte-msg-form-btn"));
  const label = button.textContent;
  buttons.forEach((b) => {
    b.disabled = true;
  });
  button.textContent = "…";
  errorEl.hidden = true;
  errorEl.textContent = "";

  try {
    await apiCall(
      `/byte/actions/${encodeURIComponent(requestId)}/respond`,
      "POST",
      // An alternate acts on what the form was posted with, so sending the
      // fields alongside it would only invite the server to read them.
      { form: spec.sends === false ? {} : readAll(container), action_key: spec.key },
    );
    // The server broadcast re-renders this as a read-only summary, so there is
    // nothing to do here but stop holding the draft.
    DRAFTS.delete(requestId);
  } catch (e) {
    // Everything they typed is still on screen and still in the draft, so the
    // only job left is saying what was wrong.
    buttons.forEach((b) => {
      b.disabled = false;
    });
    button.textContent = label;
    const reasons =
      Array.isArray(e?.errors) && e.errors.length
        ? e.errors
        : ["Couldn't send that just now — try again."];
    errorEl.textContent = reasons.join(" · ");
    errorEl.hidden = false;
  }
}
