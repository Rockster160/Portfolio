// The reminders manager, opened from the Byte drawer.
//
// Everything Buddy is holding for later, in one list: clock reminders
// ("at 4pm tomorrow") and condition watches ("next time someone's at the front
// door"). Two tables, one promise from this side, so `type` rides with the id
// and picks which one a row addresses.
//
// Setting one is still a conversation. What conversation is bad at is exactly
// what this is for: seeing all of them at once, fixing one, muting one, and
// throwing one away.
//
// Editable here: the words, the schedule (a repeat's rule, not just its hour),
// and a hand-written watch's condition. A bad listener is refused by the server
// with the old one left in place, so the risk that kept this field out — a
// half-edited condition that looks set and never fires — is already covered.
//
// A NAMED trigger (a deploy, arriving somewhere, finishing a chore) has no
// condition to type: it was assembled from structured pieces rather than
// written, so it's shown and not offered.
//
// Turning one off KEEPS it, which is why off ones stay in the list. If they
// vanished, off would be a one-way door and the only way back would be setting
// the whole thing up again.

async function apiCall(url, method, body) {
  const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
  const options = {
    method,
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-CSRF-Token": csrf },
  };
  if (body != null) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const res = await fetch(url, options);
  if (!res.ok) {
    const error = new Error(`http_${res.status}`);
    // The server says exactly what was wrong with an edit ("that's already gone
    // by", "isn't a listener that would ever fire"). Carry it so the form can
    // show it instead of inventing a vaguer version.
    error.detail = await res.json().then((b) => (b?.errors || []).join(". ")).catch(() => "");
    throw error;
  }
  if (res.status === 204) return null;
  return res.json();
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
function escapeAttr(s) { return escapeHtml(s).replace(/"/g, "&quot;"); }

export function initBuddyReminders({ list, empty, indexUrl, onCount }) {
  if (!list) return null;

  let reminders = [];
  let loading   = false;
  // Which row is open for editing, as "type:id". One at a time: two open forms
  // means two sets of unsaved values and no way to tell which is which.
  let editing   = null;

  function keyOf(r) { return `${r.type}:${r.record_id}`; }

  // `focusBody` is false when a re-paint is caused by something INSIDE the open
  // form (switching the repeat swaps the weekday field for a date one). Pulling
  // the caret back to the top field every time would make the selects unusable.
  function render({ focusBody = true } = {}) {
    if (empty) empty.hidden = reminders.length > 0;
    // The badge counts what's actually armed. A muted reminder is listed but
    // it isn't going to go off, so counting it would overstate what's watching.
    onCount?.(reminders.filter((r) => r.enabled).length);
    list.innerHTML = reminders.map((r) => (
      keyOf(r) === editing ? editorRow(r) : readRow(r)
    )).join("");
    if (focusBody) list.querySelector("[data-reminder-body]")?.focus();
  }

  function readRow(r) {
    const off = r.enabled ? "" : " byte-reminder-off";
    // A custom watch puts its raw listener on a second line, which is the
    // only thing that explains a surprise firing - so keep the break.
    const sub = escapeHtml(r.sublabel).replace(/\n/g, "<br>");
    return `
      <li class="byte-reminder${off}" data-reminder-type="${escapeHtml(r.type)}" data-reminder-id="${r.record_id}">
        <span class="byte-reminder-glyph" aria-hidden="true">${escapeHtml(r.glyph)}</span>
        <span class="byte-reminder-text">
          <span class="byte-reminder-label">${escapeHtml(r.label)}</span>
          <span class="byte-reminder-sub">${sub}</span>
        </span>
        <button type="button" class="byte-reminder-edit" data-reminder-edit aria-label="Edit">✎</button>
        <button type="button" class="byte-reminder-toggle" data-reminder-toggle aria-label="${r.enabled ? "Turn off" : "Turn on"}">${r.enabled ? "on" : "off"}</button>
        <button type="button" class="byte-reminder-remove" data-reminder-remove aria-label="Delete">×</button>
      </li>
    `;
  }

  const REPEATS = [
    ["daily", "Every day"],
    ["weekdays", "Weekdays"],
    ["weekly", "Weekly"],
    ["monthly", "Monthly"],
  ];
  const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

  function option(value, text, selected) {
    return `<option value="${escapeAttr(value)}"${value === selected ? " selected" : ""}>${escapeHtml(text)}</option>`;
  }

  // How often, plus whatever that choice hangs off — a weekday for weekly, a
  // date for monthly, nothing for the other two. Only the relevant one is
  // shown, so there's never a stale weekday sitting under "every day".
  function repeatFields(r) {
    if (!r.recurring) return "";
    const kinds = REPEATS.map(([v, t]) => option(v, t, r.repeat_kind)).join("");
    let anchor = "";
    if (r.repeat_kind === "weekly") {
      const days = WEEKDAYS.map((d) => option(d, d[0].toUpperCase() + d.slice(1), r.weekday)).join("");
      anchor = `<select class="byte-reminder-when" data-reminder-weekday>${days}</select>`;
    } else if (r.repeat_kind === "monthly") {
      // 28 is where BuddyReminder#next_fire_at clamps, so a monthly never
      // skips February. Offering 29-31 would be offering a date that moves.
      const dates = Array.from({ length: 28 }, (_, i) => option(String(i + 1), `Day ${i + 1}`, String(r.day))).join("");
      anchor = `<select class="byte-reminder-when" data-reminder-day>${dates}</select>`;
    }
    return `<select class="byte-reminder-when" data-reminder-repeat>${kinds}</select>${anchor}`;
  }

  // A hand-written watch gets its raw Jil listener; a named trigger gets the
  // same line as read-only text, because there's nothing to type into.
  function triggerField(r) {
    if (r.type !== "watch") return "";
    if (!r.custom) {
      return `<p class="byte-reminder-note">Fires on: ${escapeHtml(r.sublabel.split("\n")[0])}</p>`;
    }
    // iOS autocapitalise and autocorrect will happily turn `item:action:added`
    // into `Item:action:added`, which is a listener that matches nothing.
    return `
      <input class="byte-reminder-input byte-reminder-mono" data-reminder-listener type="text"
             value="${escapeAttr(r.listener || "")}" placeholder="Jil listener, e.g. item:action:added"
             spellcheck="false" autocapitalize="off" autocorrect="off">
    `;
  }

  // A repeating watch prints its body verbatim, so the placeholders are worth
  // saying out loud — without this the only way to know {name} works is to
  // have read WatchMatcher.
  function templateHint(r) {
    if (!r.templated) return "";
    return `<p class="byte-reminder-note">Use <code>{name}</code> for what changed. Leave it out and it's added on the end.</p>`;
  }

  function editorRow(r) {
    const timeField = r.at == null ? "" : `
      <input class="byte-reminder-when" data-reminder-at
             type="${r.recurring ? "time" : "datetime-local"}"
             value="${escapeAttr(r.at)}">
    `;
    return `
      <li class="byte-reminder byte-reminder-editing" data-reminder-type="${escapeHtml(r.type)}" data-reminder-id="${r.record_id}">
        <div class="byte-reminder-form">
          <input class="byte-reminder-input" data-reminder-body type="text" value="${escapeAttr(r.body)}" placeholder="What should it say?">
          ${templateHint(r)}
          ${timeField}
          ${repeatFields(r)}
          ${triggerField(r)}
          <div class="byte-reminder-actions">
            <button type="button" class="byte-modal-btn" data-reminder-cancel>Cancel</button>
            <button type="button" class="byte-modal-btn primary" data-reminder-save>Save</button>
          </div>
          <p class="byte-reminder-error" data-reminder-error hidden></p>
        </div>
      </li>
    `;
  }

  function adopt(data) {
    if (!data || !Array.isArray(data.reminders)) return;
    reminders = data.reminders;
    render();
  }

  async function refresh() {
    if (loading) return;
    loading = true;
    try {
      adopt(await apiCall(indexUrl, "GET"));
    } catch (e) {
      // A drawer that can't reach the server shows what it had. The reminders
      // themselves still fire - this panel is not on the path that matters.
    } finally {
      loading = false;
    }
  }

  function rowFor(el) {
    const row = el.closest?.("[data-reminder-id]");
    if (!row) return null;
    const id = Number(row.dataset.reminderId);
    const type = row.dataset.reminderType;
    return reminders.find((r) => r.record_id === id && r.type === type) || null;
  }

  function urlFor(row) {
    return `${indexUrl}/${row.type}/${row.record_id}`;
  }

  function fieldValue(li, name) {
    return li.querySelector(`[data-reminder-${name}]`)?.value;
  }

  // The server is the one that decides whether an edit was legal (a time
  // already gone by, an empty body, a listener that would never match), so its
  // own message is what gets shown. A generic "that didn't save" is useless on
  // a listener, where WHY it was refused is the entire feedback.
  async function save(row, li) {
    const err = li.querySelector("[data-reminder-error]");
    const edit = {
      body:        fieldValue(li, "body") ?? "",
      at:          fieldValue(li, "at") ?? "",
      repeat_kind: fieldValue(li, "repeat"),
      weekday:     fieldValue(li, "weekday"),
      day:         fieldValue(li, "day"),
      listener:    fieldValue(li, "listener"),
    };
    Object.keys(edit).forEach((k) => edit[k] === undefined && delete edit[k]);

    try {
      const data = await apiCall(urlFor(row), "PATCH", { reminder: edit });
      editing = null;
      adopt(data);
    } catch (e) {
      if (!err) return;
      err.hidden = false;
      err.textContent = e.detail || "That didn't save - check the fields and try again.";
    }
  }

  list.addEventListener("click", async (e) => {
    const row = rowFor(e.target);
    if (!row) return;

    if (e.target.closest("[data-reminder-edit]")) {
      editing = keyOf(row);
      render();
      return;
    }
    if (e.target.closest("[data-reminder-cancel]")) {
      editing = null;
      render();
      return;
    }
    if (e.target.closest("[data-reminder-save]")) {
      save(row, e.target.closest("[data-reminder-id]"));
      return;
    }
    if (e.target.closest("[data-reminder-toggle]")) {
      try {
        adopt(await apiCall(urlFor(row), "PATCH", { reminder: { enabled: !row.enabled } }));
      } catch (err) {
        // Re-paint from what the server last told us rather than leaving the
        // switch showing a state that didn't save.
        render();
      }
      return;
    }
    if (e.target.closest("[data-reminder-remove]")) {
      if (!window.confirm(`Delete "${row.label}"?`)) return;
      try {
        await apiCall(urlFor(row), "DELETE");
        reminders = reminders.filter((r) => !(r.record_id === row.record_id && r.type === row.type));
        render();
      } catch (err) {}
    }
  });

  // Switching how often it repeats changes WHAT ELSE the form needs to ask -
  // weekly wants a weekday, monthly wants a date, the other two want neither.
  // Held on the row so the swap survives the re-paint; it's only committed on
  // Save like every other field here.
  list.addEventListener("change", (e) => {
    if (!e.target.closest("[data-reminder-repeat]")) return;
    const row = rowFor(e.target);
    if (!row) return;

    row.repeat_kind = e.target.value;
    render({ focusBody: false });
    list.querySelector("[data-reminder-repeat]")?.focus();
  });

  // Enter saves, Escape backs out - the same two keys the rest of the app's
  // small inline edits answer to.
  list.addEventListener("keydown", (e) => {
    if (!editing) return;
    const row = rowFor(e.target);
    if (!row) return;

    if (e.key === "Enter") {
      e.preventDefault();
      save(row, e.target.closest("[data-reminder-id]"));
    } else if (e.key === "Escape") {
      editing = null;
      render();
    }
  });

  return { refresh };
}
