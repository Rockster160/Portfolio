// The reminders manager, opened from the Byte drawer.
//
// Everything Buddy is holding for later, in one list: clock reminders
// ("at 4pm tomorrow") and condition watches ("next time someone's at the front
// door"). Two tables, one promise from this side, so `type` rides with the id
// and picks which one a row addresses.
//
// Setting one is still a conversation — the interesting part of a reminder is
// its wording and its trigger, and a watch validates its listener when it's
// written. What conversation is bad at is exactly what this is for: seeing all
// of them at once, muting one, and throwing one away.
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
  if (!res.ok) throw new Error(`http_${res.status}`);
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
    list.innerHTML = reminders.map((r) => {
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
          <button type="button" class="byte-reminder-toggle" data-reminder-toggle aria-label="${r.enabled ? "Turn off" : "Turn on"}">${r.enabled ? "on" : "off"}</button>
          <button type="button" class="byte-reminder-remove" data-reminder-remove aria-label="Delete">×</button>
        </li>
      `;
    }).join("");
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

  list.addEventListener("click", async (e) => {
    const row = rowFor(e.target);
    if (!row) return;

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

  return { refresh };
}
