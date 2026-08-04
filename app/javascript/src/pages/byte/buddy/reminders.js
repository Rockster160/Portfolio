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
// Editable: the words (a Liquid template, with a live preview), the whole
// repeat RULE, and a hand-written watch's condition. A bad listener or a
// template that won't parse is refused by the server with the old one left in
// place, so the risk that kept those fields out — something half-edited that
// looks set and never fires — is covered by the thing that saves them.
//
// A NAMED trigger (a deploy, arriving somewhere, finishing a chore) has no
// condition to type: it was assembled from structured pieces rather than
// written, so it's shown and not offered.
//
// Editing happens in a MODAL rather than inline. A repeat rule is half a dozen
// controls that switch each other on and off — weekly wants days, monthly wants
// dates or an Nth weekday, custom wants an interval — and the body needs room
// for a preview underneath. None of that fits in a list row.
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
export function initBuddyReminders({ list, empty, indexUrl, onCount }) {
  if (!list) return null;

  let reminders = [];
  let loading   = false;

  function render() {
    if (empty) empty.hidden = reminders.length > 0;
    // The badge counts what's actually armed. A muted reminder is listed but
    // it isn't going to go off, so counting it would overstate what's watching.
    onCount?.(reminders.filter((r) => r.enabled).length);
    list.innerHTML = reminders.map(readRow).join("");
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

  // ---- the editor modal ----------------------------------------------------

  const WEEKDAY_KEYS  = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
  const WEEKDAY_LABEL = ["S", "M", "T", "W", "T", "F", "S"];
  const modal = document.querySelector("[data-byte-reminder-edit]");
  const field = (name) => modal?.querySelector(`[data-byte-edit-${name}]`);

  // The row being edited, and a working copy of the parts that switch other
  // controls on and off. Held here rather than read back out of the DOM so
  // toggling weekly→monthly doesn't lose what was typed on the way past.
  let editing = null;
  let draft   = {};
  let previewTimer = null;

  function openEditor(row) {
    if (!modal) return;
    editing = row;
    draft = {
      freq:         row.freq || "daily",
      by_day:       (row.by_day || []).slice(),
      by_month_day: (row.by_month_day || []).slice(),
      by_set_pos:   row.by_set_pos || null,
      interval:     row.interval || 1,
      unit:         row.unit || "week",
    };

    field("title").textContent = row.type === "watch" ? "Edit watch" : "Edit reminder";
    field("body").value        = row.body || "";
    field("error").hidden      = true;
    paintWhen(row);
    paintRepeat();
    paintTrigger(row);
    refreshPreview();
    // Same open/close shape the other Byte managers use, fallback included —
    // this stacks on top of the reminders list, which is itself a dialog.
    if (typeof modal.showModal === "function") modal.showModal();
    else modal.setAttribute("open", "");
    field("body").focus();
  }

  function closeEditor() {
    editing = null;
    if (typeof modal?.close === "function") modal.close();
    else modal?.removeAttribute("open");
  }

  // A one-off has a date and a time; a repeat has a rule; a watch has neither,
  // because it fires on a condition.
  function paintWhen(row) {
    const when = field("when");
    when.hidden = row.at == null || row.recurring;
    if (!when.hidden) field("at").value = row.at || "";
    field("repeat").hidden = !row.recurring;
    if (row.recurring) field("time").value = row.at || "";
    field("until").value = row.until_on || "";
  }

  function paintRepeat() {
    if (field("repeat").hidden) return;
    field("freq").value = draft.freq;

    const weekly = draft.freq === "weekly";
    field("days").hidden = !weekly;
    if (weekly) paintDays();

    const monthly = draft.freq === "monthly";
    field("monthly").hidden = !monthly;
    if (monthly) paintMonthly();

    const custom = draft.freq === "custom";
    field("custom").hidden = !custom;
    if (custom) {
      field("interval").value = draft.interval;
      field("unit").value = draft.unit;
    }
    field("summary").textContent = summarize();
  }

  function paintDays() {
    field("days").innerHTML = WEEKDAY_KEYS.map((key, i) => {
      const on = draft.by_day.includes(key) ? " on" : "";
      return `<button type="button" class="byte-edit-day${on}" data-day="${key}">${WEEKDAY_LABEL[i]}</button>`;
    }).join("");
  }

  // Monthly is two rules wearing one name: particular dates, or the Nth
  // weekday. Showing both sets of inputs at once would make it unclear which
  // one is in force, so the mode picks.
  function paintMonthly() {
    const nth = draft.by_set_pos != null;
    field("monthmode").value = nth ? "nth" : "date";
    field("monthdays").hidden = nth;
    field("setpos").hidden = !nth;
    field("days").hidden = !nth;
    if (nth) {
      field("setpos").value = String(draft.by_set_pos);
      paintDays();
    } else {
      field("monthdays").value = draft.by_month_day.join(", ");
    }
  }

  // Says the rule back in words. The controls are legible one at a time and
  // opaque together — "every 2 weeks on Tuesday" is the check that what got
  // clicked is what was meant.
  function summarize() {
    const at = field("time").value || "";
    const days = draft.by_day.map((k) => WEEKDAY_KEYS.indexOf(k))
      .sort((a, b) => a - b)
      .map((i) => ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][i]);
    const ordinal = { "1": "first", "2": "second", "3": "third", "4": "fourth", "-1": "last" };
    let base;
    switch (draft.freq) {
      case "weekdays": base = "Every weekday"; break;
      case "weekly":   base = days.length ? `Every ${days.join(", ")}` : "Every week"; break;
      case "yearly":   base = "Once a year"; break;
      case "custom":   base = `Every ${draft.interval} ${draft.unit}${draft.interval > 1 ? "s" : ""}`; break;
      case "monthly":
        base = draft.by_set_pos != null
          ? `The ${ordinal[String(draft.by_set_pos)]} ${days[0] || "day"} of each month`
          : `Day ${draft.by_month_day.join(", ") || "1"} of each month`;
        break;
      default: base = "Every day";
    }
    const until = field("until").value;
    return `${base}${at ? ` at ${at}` : ""}${until ? `, until ${until}` : ""}`;
  }

  function paintTrigger(row) {
    const isWatch = row.type === "watch";
    field("trigger-row").hidden = !isWatch || !row.custom;
    field("trigger-note").hidden = !isWatch || row.custom;
    if (isWatch && row.custom) field("listener").value = row.listener || "";
    if (isWatch && !row.custom) {
      field("trigger-note").textContent = `Fires on: ${(row.sublabel || "").split("\n")[0]}`;
    }
  }

  // What the words would actually come out as, rendered by the server because
  // the server is what renders them for real. Debounced — this fires on every
  // keystroke and it's a round trip.
  function refreshPreview() {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(async () => {
      const body = field("body").value;
      try {
        const data = await apiCall(`${indexUrl}/preview`, "POST", { body });
        const out = field("preview");
        const vars = field("vars");
        out.hidden = !data.preview && !data.error;
        out.classList.toggle("byte-edit-preview-bad", !!data.error);
        out.textContent = data.error ? data.error : data.preview;
        vars.hidden = !data.variables;
        if (data.variables) {
          vars.innerHTML = `Available: ${Object.keys(data.variables).map((k) => `<code>{{ ${escapeHtml(k)} }}</code>`).join(" ")}`;
        }
      } catch (e) {
        field("preview").hidden = true;
      }
    }, 250);
  }

  async function saveEditor() {
    if (!editing) return;
    const edit = { body: field("body").value };

    if (editing.recurring) {
      edit.at = field("time").value;
      edit.until_on = field("until").value;
      edit.freq = draft.freq;
      if (draft.freq === "weekly") edit.by_day = draft.by_day;
      if (draft.freq === "monthly" && draft.by_set_pos != null) {
        edit.by_set_pos = draft.by_set_pos;
        edit.by_day = draft.by_day.slice(0, 1);
      } else if (draft.freq === "monthly") {
        edit.by_month_day = parseDays(field("monthdays").value);
      }
      if (draft.freq === "custom") {
        edit.interval = field("interval").value;
        edit.unit = field("unit").value;
      }
    } else if (editing.at != null) {
      edit.at = field("at").value;
    }
    if (editing.type === "watch" && editing.custom) edit.listener = field("listener").value;

    try {
      const data = await apiCall(urlFor(editing), "PATCH", { reminder: edit });
      closeEditor();
      adopt(data);
    } catch (e) {
      const err = field("error");
      err.hidden = false;
      err.textContent = e.detail || "That didn't save - check the fields and try again.";
    }
  }

  function parseDays(text) {
    return String(text || "").split(",")
      .map((n) => parseInt(n.trim(), 10))
      .filter((n) => !Number.isNaN(n));
  }

  modal?.addEventListener("click", (e) => {
    if (e.target.closest("[data-byte-edit-cancel]")) return closeEditor();
    if (e.target.closest("[data-byte-edit-save]")) return saveEditor();

    const day = e.target.closest("[data-day]");
    if (!day) return;
    // Weekly takes any combination; the Nth-weekday-of-month rule takes
    // exactly one, so picking there replaces rather than adds.
    const key = day.dataset.day;
    if (draft.freq === "monthly") {
      draft.by_day = [key];
    } else {
      draft.by_day = draft.by_day.includes(key)
        ? draft.by_day.filter((d) => d !== key)
        : draft.by_day.concat(key);
    }
    paintRepeat();
  });

  modal?.addEventListener("input", (e) => {
    if (e.target.closest("[data-byte-edit-body]")) refreshPreview();
  });

  modal?.addEventListener("change", (e) => {
    if (e.target.closest("[data-byte-edit-freq]")) {
      draft.freq = field("freq").value;
      // Each frequency hangs off something different, so switching seeds a
      // sensible default for whatever the new one needs and drops what the
      // old one used. The server drops the stale keys too; this is so the
      // form never shows a blank set of days.
      if (draft.freq === "weekly" && draft.by_day.length === 0) draft.by_day = ["mon"];
      if (draft.freq === "monthly" && draft.by_set_pos == null && draft.by_month_day.length === 0) {
        draft.by_month_day = [1];
      }
    }
    if (e.target.closest("[data-byte-edit-monthmode]")) {
      const nth = field("monthmode").value === "nth";
      draft.by_set_pos = nth ? Number(field("setpos").value || 1) : null;
      if (nth && draft.by_day.length === 0) draft.by_day = ["mon"];
    }
    if (e.target.closest("[data-byte-edit-setpos]")) draft.by_set_pos = Number(field("setpos").value);
    if (e.target.closest("[data-byte-edit-interval]")) draft.interval = Number(field("interval").value || 1);
    if (e.target.closest("[data-byte-edit-unit]")) draft.unit = field("unit").value;
    if (e.target.closest("[data-byte-edit-monthdays]")) draft.by_month_day = parseDays(field("monthdays").value);
    paintRepeat();
  });

  modal?.addEventListener("close", () => { editing = null; });

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

  list.addEventListener("click", async (e) => {
    const row = rowFor(e.target);
    if (!row) return;

    if (e.target.closest("[data-reminder-edit]")) {
      openEditor(row);
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

  // Enter saves from any single-line field. Not the body: that's a textarea
  // now, and a template with a conditional in it wants to wrap. Escape is
  // handled by <dialog> itself.
  modal?.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.target.tagName === "TEXTAREA") return;
    e.preventDefault();
    saveEditor();
  });

  return { refresh };
}
