// The saved-routines manager, opened from the Byte drawer.
//
// Read-mostly by design. A routine's STEPS are tool calls with validated
// arguments, which is a bad thing to hand-edit in a text box, so they're
// written by talking to Byte (`save_routine`). What's useful here is the part
// conversation is bad at: seeing everything you've saved at once, fixing a
// name, muting one without losing it, and throwing one away.
//
// Hydrated when the drawer opens rather than at boot — most sessions never
// open it, and the list is only interesting once it's on screen.
//
// Pinning is the one thing here that isn't housekeeping. Every enabled routine
// is already on the Quick grid and the wall tablet; starring one moves it to
// the front of both, and their order there is the order they drag them into.

import Sortable from "../../../../jil/Sortable.min.js";

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
function escapeAttr(s) { return escapeHtml(s).replace(/"/g, "&quot;"); }

export function initBuddyRoutines({ panel, list, empty, indexUrl, onCount, addBtn, picker, pickerList, pickerEmpty }) {
  if (!panel || !list) return null;

  let routines = [];
  let loading  = false;
  let sortable = null;

  // Pinned first, in grid order, so the drawer reads the way the Quick grid
  // looks — dragging one here is only meaningful if you can see the order
  // you're dragging it into.
  function pinned() {
    return routines
      .filter((r) => r.position != null)
      .sort((a, b) => a.position - b.position);
  }

  function sorted() {
    return pinned().concat(routines.filter((r) => r.position == null));
  }

  function pinnedIds() {
    return pinned().map((r) => r.id);
  }

  function render() {
    // The panel is a dialog you deliberately opened, so an empty one owes you
    // an explanation rather than hiding itself the way the inline drawer
    // section used to.
    if (empty) empty.hidden = routines.length > 0;
    onCount?.(routines.length);
    list.innerHTML = sorted().map((r) => {
      const steps  = (r.summary || []).map((s) => `<li>${escapeHtml(s)}</li>`).join("");
      const off    = r.enabled ? "" : " byte-routine-off";
      const isPin  = r.position != null;
      // Only pinned rows are draggable: the order being dragged into is the
      // Quick grid's, and an unpinned routine isn't on it.
      const drag   = isPin ? " byte-routine-pinned" : "";
      // The grip is separate from the star on purpose: the star is a tap and
      // the grip is a drag, and one element answering to both means every
      // slightly-moved tap is ambiguous.
      const handle = `<span class="byte-routine-grip" data-routine-grip aria-hidden="true">⠿</span>`;
      const grip   = isPin ? handle : "";
      // "Front" rather than "add/remove": every enabled routine is already on
      // the Quick grid and the wall, and starring is what moves it up.
      const pinTip = isPin ? "Unpin from the front" : "Pin to the front";
      return `
        <li class="byte-routine${off}${drag}" data-routine-id="${r.id}">
          <div class="byte-routine-head">
            ${grip}
            <button type="button" class="byte-routine-pin" data-routine-pin aria-pressed="${isPin}" title="${pinTip}" aria-label="${pinTip}">${isPin ? "★" : "☆"}</button>
            <button type="button" class="byte-routine-name" data-routine-rename title="Rename">${escapeHtml(r.name)}</button>
            <button type="button" class="byte-routine-toggle" data-routine-toggle aria-label="${r.enabled ? "Turn off" : "Turn on"}">${r.enabled ? "on" : "off"}</button>
            <button type="button" class="byte-routine-remove" data-routine-remove aria-label="Delete">×</button>
          </div>
          ${r.description ? `<p class="byte-routine-desc">${escapeHtml(r.description)}</p>` : ""}
          <ol class="byte-routine-steps">${steps}</ol>
        </li>
      `;
    }).join("");
    bindSortable();
  }

  // Rebuilt after every render because render() replaces the whole list.
  function bindSortable() {
    sortable?.destroy();
    sortable = Sortable.create(list, {
      animation:     150,
      draggable:     ".byte-routine-pinned",
      handle:        ".byte-routine-grip",
      ghostClass:    "byte-routine-ghost",
      // Matches the timers board: the native HTML5 drag is unreliable inside a
      // scrolling drawer on iOS.
      forceFallback:     true,
      fallbackOnBody:    true,
      fallbackTolerance: 0,
      onEnd: () => {
        const ids = Array.from(list.querySelectorAll(".byte-routine-pinned"))
          .map((el) => Number(el.dataset.routineId))
          .filter(Boolean);
        reorder(ids);
      },
    });
  }

  // One request for the whole grid. Positions are rewritten from the list sent,
  // and anything left out is unpinned — so this is pin, unpin and reorder.
  async function reorder(ids) {
    try {
      const data = await apiCall(`${indexUrl}/reorder`, "POST", { ids });
      if (data && Array.isArray(data.routines)) {
        routines = data.routines;
        render();
      }
    } catch (e) {
      // Put the rows back where the server still thinks they are, rather than
      // leaving the drag showing an order that didn't save.
      render();
    }
  }

  async function refresh() {
    if (loading) return;
    loading = true;
    try {
      const data = await apiCall(indexUrl, "GET");
      if (data && Array.isArray(data.routines)) {
        routines = data.routines;
        render();
      }
    } catch (e) {
      // A drawer that can't reach the server just shows what it had. The
      // routines still run — this panel is not on the path that matters.
    } finally {
      loading = false;
    }
  }

  function routineFor(el) {
    const row = el.closest?.("[data-routine-id]");
    if (!row) return null;
    const id = Number(row.dataset.routineId);
    return routines.find((r) => r.id === id) || null;
  }

  async function patch(routine, attrs) {
    try {
      const updated = await apiCall(`${indexUrl}/${routine.id}`, "PATCH", { routine: attrs });
      if (!updated) return;
      const i = routines.findIndex((r) => r.id === routine.id);
      if (i >= 0) routines[i] = updated;
      render();
    } catch (e) {}
  }

  // ---- adding a Jil automation as a one-tap button ----
  //
  // The server only offers the ones firable by name alone. A task with data
  // filters on its listener needs a payload built, and there's nowhere on a
  // button to say what that payload is — so those stay conversational rather
  // than becoming a button that looks fine and never fires.

  function paintPicker(actions) {
    if (!pickerList) return;
    if (pickerEmpty) pickerEmpty.hidden = actions.length > 0;
    pickerList.innerHTML = actions.map((a) => `
      <li class="byte-jil-action" data-jil-id="${a.id}" data-jil-name="${escapeAttr(a.name)}">
        <button type="button" class="byte-jil-add" data-jil-add>
          <span class="byte-jil-name">${escapeHtml(a.name)}</span>
          ${a.description ? `<span class="byte-jil-desc">${escapeHtml(a.description)}</span>` : ""}
        </button>
      </li>
    `).join("");
  }

  async function togglePicker() {
    if (!picker) return;
    if (!picker.hidden) {
      picker.hidden = true;
      return;
    }
    picker.hidden = false;
    try {
      const data = await apiCall(`${indexUrl}/jil_actions`, "GET");
      paintPicker(Array.isArray(data?.actions) ? data.actions : []);
    } catch (e) {
      paintPicker([]);
    }
  }

  async function addJil(id, taskName) {
    // Prefilled with the automation's own name, because that's usually right,
    // and editable because a wall button wants "Preheat" where the task is
    // called "Printer - Preheat".
    const label = window.prompt("Button label", taskName);
    if (label === null) return;

    try {
      await apiCall(indexUrl, "POST", { task_id: id, name: label.trim() || taskName });
      if (picker) picker.hidden = true;
      await refresh();
    } catch (e) {
      window.alert("Couldn't add that one.");
    }
  }

  addBtn?.addEventListener("click", togglePicker);
  pickerList?.addEventListener("click", (e) => {
    const row = e.target.closest?.("[data-jil-id]");
    if (row && e.target.closest("[data-jil-add]")) addJil(Number(row.dataset.jilId), row.dataset.jilName);
  });

  list.addEventListener("click", async (e) => {
    const routine = routineFor(e.target);
    if (!routine) return;

    if (e.target.closest("[data-routine-pin]")) {
      const ids = pinnedIds();
      reorder(routine.position == null ? ids.concat(routine.id) : ids.filter((id) => id !== routine.id));
      return;
    }
    if (e.target.closest("[data-routine-toggle]")) {
      patch(routine, { enabled: !routine.enabled });
      return;
    }
    if (e.target.closest("[data-routine-rename]")) {
      const name = window.prompt("Rename routine", routine.name);
      if (name && name.trim() && name.trim() !== routine.name) patch(routine, { name: name.trim() });
      return;
    }
    if (e.target.closest("[data-routine-remove]")) {
      if (!window.confirm(`Delete "${routine.name}"?`)) return;
      try {
        await apiCall(`${indexUrl}/${routine.id}`, "DELETE");
        routines = routines.filter((r) => r.id !== routine.id);
        render();
      } catch (err) {}
    }
  });

  return { refresh };
}
