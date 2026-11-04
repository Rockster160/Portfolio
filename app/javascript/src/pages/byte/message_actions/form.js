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
//   2. A rebuild while someone is typing moves the caret. So while focus is
//      in a box being typed in, nothing is rebuilt: values change in place,
//      and the box with focus takes its own the moment focus leaves it.
//
// A repaint is also how the server PUSHES to a form already on screen - a
// guess that took a while, a duration still running. A push may only change a
// value the person hasn't: each form remembers what it last showed, and a box
// still holding that is the server's to update, however many times it was
// focused or typed in and put back. Labels and small print are the server's
// alone and always land. A push that changes the form's SHAPE - fields or
// their options added, removed or reordered - is not applied at all; the
// refresh button says so, and pressing it rebuilds the whole form from the
// server, edits included.
//
// Field types mirror shared/_dynamic_form_fields, since the app's own Prompt
// pages are the first thing this renders.

import {
  parseDurationMinutes,
  formatDurationHint,
} from "../../../support/parse_duration.js";

// requestId -> { key: value }. Module-level so it survives any number of
// repaints, and deliberately not localStorage: a draft is only interesting
// while the thread is open, and a stale one resurfacing on another device would
// be worse than none.
const DRAFTS = new Map();

// requestId -> what the refresh in flight is for, so a repaint that lands
// mid-request keeps the arrows turning and is painted the way that refresh
// asked: OPENED (shown for the first time - take the new shape, keep edits) or
// REPLACE (the button - take everything). Anything else is a push. And the
// ones already refreshed on being shown, since a history refetch repaints
// every message and each would ask again.
const REFRESHING = new Map();
const SHOWN = new Set();
const OPENED = "opened";
const REPLACE = "replace";

// requestId -> { fields, shape, shown: { key: normalized value }, stale }:
// the form as it was last painted. `shown` is what each box held when the
// server last set it, and is what "changed by the person" is measured from.
const PAINTED = new Map();

// requestId -> every container drawing it (the thread, the kiosk), so a
// refresh's answer can be painted even if its broadcast never arrives.
const MOUNTS = new Map();

// container -> the repaint held back while someone types in it, for the one
// kind that can't be done in place: an opening refresh changing the shape.
const HELD = new WeakMap();

// Rows already waiting for focus to leave them.
const LANDING = new WeakSet();

const REFRESH_ICON = `
  <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
    <path fill="currentColor" d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35Z"/>
  </svg>`;

const INPUT_TYPES = {
  text: "text",
  // Not "number" — that widget refuses "1:32" and "1h 32" as they are typed.
  duration: "text",
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

function isEditing(el) {
  if (el.matches("textarea, select")) return true;
  return el.matches("input") && !["checkbox", "radio", "button", "submit"].includes(el.type);
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
  const mode = REFRESHING.get(requestId);

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

  // Never rebuild under someone's cursor. Only a control that takes typing or
  // dragging counts: the refresh button keeps focus after a tap, and the
  // repaint it asked for is the one it is waiting on.
  const active = document.activeElement;
  if (!locked && mode !== REPLACE && PAINTED.has(requestId) && container.contains(active) && isEditing(active)) {
    if (mode === OPENED && shapeOf(form.fields) !== PAINTED.get(requestId).shape) {
      holdUntilBlur(container, message);
    } else {
      updateInPlace(container, requestId, form.fields, draftFor(requestId), mode, active);
    }
    return true;
  }
  HELD.delete(container);
  if (requestId) mountsFor(requestId).add(container);

  // A settled form shows what was actually recorded, never a local draft. The
  // answer may have been given somewhere else entirely — the prompt's own page
  // — in which case a half-typed guess sitting here is pure fiction.
  if (locked) {
    DRAFTS.delete(requestId);
    PAINTED.delete(requestId);
  }
  if (mode === REPLACE) DRAFTS.delete(requestId);
  const draft = locked ? {} : draftFor(requestId);
  const painted = locked
    ? { fields: form.fields, stale: false }
    : settle(requestId, form.fields, draft, mode);

  container.innerHTML = "";
  container.className = "byte-msg-form";
  container.dataset.status = submitted
    ? "submitted"
    : superseded
      ? "superseded"
      : expired
        ? "expired"
        : "pending";

  // A form that fills itself in when it's opened. What it was posted with
  // shows straight away and is rebuilt behind it, so nothing waits on this.
  const refreshable = !locked && requestId && (form.refresh || painted.stale);
  if (refreshable) {
    container.appendChild(refreshButton(requestId, painted.stale));
    if (form.refresh && !SHOWN.has(requestId)) {
      SHOWN.add(requestId);
      setTimeout(() => refreshForm(requestId, OPENED), 0);
    }
  }

  painted.fields.forEach((field) => {
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

// What a painted form becomes when this version of it arrives. Fields keep
// the shape already on screen unless this repaint may change it, and take the
// server's value wherever the person hasn't changed theirs.
//
// `focusedKey` is the box being typed in. Unless it has been changed, it keeps
// what it shows for now and its new value waits in `waiting` for focus to
// leave it.
function settle(requestId, incoming, draft, mode, focusedKey = null) {
  const before = PAINTED.get(requestId);
  const shape = shapeOf(incoming);
  const reshape = !before || mode === OPENED || mode === REPLACE || shape === before.shape;
  const base = reshape ? incoming : before.fields;
  const fresh = new Map(incoming.map((field) => [field.key, field]));

  const shown = {};
  const waiting = {};
  const fields = base.map((baseField) => {
    let field = baseField;
    const server = fresh.has(field.key) ? fresh.get(field.key).value : field.value;
    // Words only - a label or its small print - so it lands whatever the
    // shape is doing.
    const words = fresh.get(field.key);
    if (words) field = { ...field, label: words.label, hint: words.hint };
    const edited =
      Object.prototype.hasOwnProperty.call(draft, field.key) &&
      (!before || normalized(field, draft[field.key]) !== before.shown[field.key]);

    if (edited) {
      shown[field.key] = before?.shown[field.key] ?? normalized(field, server);
      return { ...field, value: draft[field.key] };
    }
    if (before && field.key === focusedKey) {
      shown[field.key] = before.shown[field.key];
      waiting[field.key] = server;
      const onScreen = before.fields.find((f) => f.key === field.key);
      return { ...field, value: onScreen ? onScreen.value : server };
    }
    delete draft[field.key];
    shown[field.key] = normalized(field, server);
    return { ...field, value: server };
  });

  const state = { fields, shape: reshape ? shape : before.shape, shown, waiting, stale: !reshape };
  PAINTED.set(requestId, state);
  return state;
}

// Everything about a form except its values and its words: which fields, in
// what order, what kind of control each is, and its options in their order.
function shapeOf(fields) {
  return JSON.stringify(
    fields.map((f) => [f.key, f.type, !!f.required, f.choices ?? null, f.min ?? null, f.max ?? null, f.step ?? null]),
  );
}

// A value as the box holding it would read it back, so a field the server
// sent as nothing and the person never moved compares equal however it is
// spelled - null, "", an unticked box, a slider resting on its floor, a
// required select sitting on its first choice.
function normalized(field, value) {
  const blank = value == null || value === "";
  switch (field.type) {
    case "checkbox":
      return String(value) === "true" ? "true" : "false";
    case "choices":
      return (Array.isArray(value) ? value : String(value ?? "").split(","))
        .map((v) => String(v).trim())
        .filter(Boolean)
        .sort()
        .join(",");
    case "scale":
      return blank ? String(field.min ?? 0) : String(value);
    case "select":
      return blank && field.required ? String(field.choices?.[0] ?? "") : blank ? "" : String(value);
    default:
      return blank ? "" : String(value);
  }
}

// A push landing while someone is typing in the form. Every other box that
// still holds what the server last gave it takes the new value now; the one
// with focus takes it when focus leaves, if it is still unchanged by then.
function updateInPlace(container, requestId, incoming, draft, mode, active) {
  const rows = Array.from(container.querySelectorAll(".byte-msg-form-row"));
  const focusedRow = rows.find((row) => row.contains(active));
  const focusedKey = focusedRow?.dataset.key ?? null;
  const painted = settle(requestId, incoming, draft, mode, focusedKey);

  painted.fields.forEach((field) => {
    const row = rows.find((r) => r.dataset.key === field.key);
    if (!row) return;
    paintLabel(row, field);
    paintServerHint(row, field);
    if (row === focusedRow) return;
    if (normalized(field, readRow(row)) !== normalized(field, field.value)) writeRow(row, field);
  });

  const button = container.querySelector(".byte-msg-form-refresh");
  if (button) paintStale(button, painted.stale);
  else if (painted.stale) container.insertBefore(refreshButton(requestId, true), container.firstChild);

  if (focusedRow && Object.prototype.hasOwnProperty.call(painted.waiting, focusedKey)) {
    landOnBlur(focusedRow, requestId, focusedKey);
  }
}

function landOnBlur(row, requestId, key) {
  if (LANDING.has(row)) return;
  LANDING.add(row);

  const land = () => {
    setTimeout(() => {
      // Still inside the row - one checkbox of several to the next.
      if (row.contains(document.activeElement)) return;
      row.removeEventListener("focusout", land);
      LANDING.delete(row);

      const state = PAINTED.get(requestId);
      if (!state || !Object.prototype.hasOwnProperty.call(state.waiting, key)) return;
      const server = state.waiting[key];
      delete state.waiting[key];
      const field = state.fields.find((f) => f.key === key);
      // They typed something after all, which the draft already holds.
      if (!field || normalized(field, readRow(row)) !== state.shown[key]) return;

      field.value = server;
      writeRow(row, field);
      state.shown[key] = normalized(field, server);
      delete draftFor(requestId)[key];
    }, 0);
  };
  row.addEventListener("focusout", land);
}

// One box set to `field.value`, the way buildControl would have drawn it.
function writeRow(row, field) {
  const value = field.value;
  const blank = value == null || value === "";
  const type = row.dataset.type;

  if (type === "choices") {
    const picked = new Set(
      (Array.isArray(value) ? value : String(value ?? "").split(","))
        .map((v) => String(v).trim())
        .filter(Boolean),
    );
    row.querySelectorAll('input[type="checkbox"]').forEach((cb) => {
      cb.checked = picked.has(cb.value);
    });
  } else if (type === "chips") {
    row.querySelectorAll('input[type="radio"]').forEach((radio) => {
      radio.checked = !blank && String(value) === radio.value;
    });
  } else if (type === "checkbox") {
    const cb = row.querySelector('input[type="checkbox"]');
    if (cb) cb.checked = String(value) === "true";
  } else if (type === "scale") {
    const range = row.querySelector("input");
    if (range) range.value = blank ? range.min : String(value);
    const out = row.querySelector(".byte-msg-form-scale-value");
    if (out && range) out.textContent = range.value;
  } else if (type === "select") {
    const sel = row.querySelector("select");
    if (sel && !blank) sel.value = String(value);
    else if (sel && field.required) sel.selectedIndex = 0;
    else if (sel) sel.value = "";
  } else {
    const box = row.querySelector("input, textarea");
    if (box) box.value = blank ? "" : String(value);
  }
  row.byteRepaint?.();
}

function paintLabel(row, field) {
  const label = row.querySelector(".byte-msg-form-label");
  if (label) fillLabel(label, field);
}

// "Sleepy | Alert" names the two ends of a scale, which the page draws on
// either side of the slider rather than as one label.
function fillLabel(label, field) {
  const ends = scaleEnds(field);
  label.innerHTML = "";
  label.classList.toggle("byte-msg-form-ends", !!ends);
  if (ends) {
    ends.forEach((end) => {
      const span = document.createElement("span");
      span.textContent = end;
      label.appendChild(span);
    });
  } else {
    label.textContent = field.label || field.key;
  }
}

// The small print the server sends with a field.
function paintServerHint(row, field) {
  let hint = row.querySelector(".byte-msg-form-hint-server");
  if (!hint && !field.hint) return;
  if (!hint) {
    hint = document.createElement("span");
    hint.className = "byte-msg-form-hint byte-msg-form-hint-server";
    row.appendChild(hint);
  }
  hint.textContent = field.hint || "";
  hint.hidden = !field.hint;
}

function mountsFor(requestId) {
  if (!MOUNTS.has(requestId)) MOUNTS.set(requestId, new Set());
  return MOUNTS.get(requestId);
}

// The latest repaint wins; it lands once focus has left the whole form, not
// when it moves from one of its boxes to the next.
function holdUntilBlur(container, message) {
  const waiting = HELD.has(container);
  HELD.set(container, message);
  if (waiting) return;

  const retry = () => {
    setTimeout(() => {
      if (!HELD.has(container)) {
        container.removeEventListener("focusout", retry);
        return;
      }
      if (container.contains(document.activeElement)) return;
      container.removeEventListener("focusout", retry);
      const held = HELD.get(container);
      HELD.delete(container);
      renderForm(container, held);
    }, 0);
  };
  container.addEventListener("focusout", retry);
}

function refreshButton(requestId, stale) {
  const bar = document.createElement("div");
  bar.className = "byte-msg-form-top";
  const button = document.createElement("button");
  button.type = "button";
  button.className = "byte-msg-form-refresh";
  button.dataset.refreshFor = requestId;
  button.innerHTML = REFRESH_ICON;
  paintStale(button, stale);
  paintRefreshing(button, REFRESHING.has(requestId));
  button.addEventListener("click", () => refreshForm(requestId, REPLACE));
  bar.appendChild(button);
  return bar;
}

function paintStale(button, stale) {
  const title = stale ? "This form changed - refresh to see it" : "Refresh";
  button.title = title;
  button.setAttribute("aria-label", title);
  button.classList.toggle("is-stale", stale);
  const mark = button.querySelector(".byte-msg-form-refresh-mark");
  if (stale && !mark) {
    const badge = document.createElement("span");
    badge.className = "byte-msg-form-refresh-mark";
    badge.textContent = "!";
    button.appendChild(badge);
  } else if (!stale && mark) {
    mark.remove();
  }
}

function paintRefreshing(button, on) {
  button.classList.toggle("is-reloading", on);
  button.setAttribute("aria-busy", on ? "true" : "false");
}

// The server rebuilds the form and broadcasts it, which repaints this message
// the same way any update does - painted as `mode` asked, since it is in
// REFRESHING until the answer is back. The answer carries the message too and
// is painted from directly, so a broadcast lost on a dropped socket doesn't
// leave the press doing nothing. The button can be a different node by then,
// so it is found again rather than held.
async function refreshForm(requestId, mode) {
  if (REFRESHING.has(requestId)) return;

  const buttons = () =>
    document.querySelectorAll(`[data-refresh-for="${CSS.escape(requestId)}"]`);
  REFRESHING.set(requestId, mode);
  buttons().forEach((b) => paintRefreshing(b, true));
  try {
    const json = await apiCall(`/byte/actions/${encodeURIComponent(requestId)}/refresh`, "POST");
    if (json?.message) {
      mountsFor(requestId).forEach((mount) => {
        if (mount.isConnected === false) mountsFor(requestId).delete(mount);
        else renderForm(mount, json.message);
      });
    }
  } catch (e) {
    console.warn("[byte] form refresh failed", e);
  } finally {
    REFRESHING.delete(requestId);
    buttons().forEach((b) => paintRefreshing(b, false));
  }
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
  fillLabel(label, field);
  row.appendChild(label);

  const control = buildControl(field, field.value, locked);
  if (!control) return null;
  row.appendChild(control);

  // A lone checkbox is a small target, and its label is the obvious thing to
  // tap. Only this one: on any other row a tap on the label would fight the
  // input for it.
  if (field.type === "checkbox" && !locked) {
    label.classList.add("byte-msg-form-label-toggle");
    label.addEventListener("click", () => control.querySelector("input")?.click());
  }

  // A duration writes its own readback and keeps rewriting it, beneath any
  // small print the server sent along with it.
  if (field.hint) {
    const hint = document.createElement("span");
    hint.className = "byte-msg-form-hint byte-msg-form-hint-server";
    hint.textContent = field.hint;
    row.appendChild(hint);
  }
  if (field.type === "duration") {
    const hint = document.createElement("span");
    hint.className = "byte-msg-form-hint";
    row.appendChild(hint);
    const paint = () => {
      const raw = readRow(row);
      const minutes = parseDurationMinutes(raw);
      if (minutes == null) {
        const unreadable = String(raw).trim().length > 0;
        hint.textContent = unreadable ? "Can't read that as a duration" : "";
        hint.dataset.unreadable = unreadable ? "true" : "false";
        return;
      }
      hint.textContent = formatDurationHint(minutes);
      hint.dataset.unreadable = "false";
    };
    row.addEventListener("input", paint);
    row.byteRepaint = paint;
    paint();
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

function scaleEnds(field) {
  if (field.type !== "scale") return null;
  const parts = String(field.label || field.key).split(" | ");
  return parts.length === 2 ? parts : null;
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

  // One of a few short options as a row of chips: radios underneath, so the
  // browser keeps it to one, and grey until picked, then the chip's own color.
  if (type === "chips") {
    const wrap = document.createElement("div");
    wrap.className = "byte-msg-form-chips";
    wrap.setAttribute("role", "radiogroup");
    const group = `chips-${field.key}-${Math.random().toString(36).slice(2)}`;
    const colors = field.colors || {};
    (field.choices || []).forEach((choice) => {
      const chip = document.createElement("label");
      chip.className = "byte-msg-form-chip";
      if (colors[choice]) chip.style.setProperty("--chip-color", colors[choice]);
      const radio = document.createElement("input");
      radio.type = "radio";
      radio.name = group;
      radio.value = choice;
      radio.checked = value != null && String(value) === choice;
      radio.disabled = locked;
      chip.appendChild(radio);
      const text = document.createElement("span");
      text.textContent = choice;
      chip.appendChild(text);
      wrap.appendChild(chip);
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
  if (type === "chips") {
    return row.querySelector('input[type="radio"]:checked')?.value ?? "";
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
    PAINTED.delete(requestId);
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
