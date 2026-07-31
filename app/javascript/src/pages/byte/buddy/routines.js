// The saved-routines panel at the bottom of the Byte drawer.
//
// Read-mostly by design. A routine's STEPS are tool calls with validated
// arguments, which is a bad thing to hand-edit in a text box, so they're
// written by talking to Byte (`save_routine`). What's useful here is the part
// conversation is bad at: seeing everything you've saved at once, fixing a
// name, muting one without losing it, and throwing one away.
//
// Hydrated when the drawer opens rather than at boot — most sessions never
// open it, and the list is only interesting once it's on screen.

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

export function initBuddyRoutines({ panel, list, indexUrl }) {
  if (!panel || !list) return null;

  let routines = [];
  let loading  = false;

  function render() {
    panel.hidden = routines.length === 0;
    list.innerHTML = routines.map((r) => {
      const steps = (r.summary || []).map((s) => `<li>${escapeHtml(s)}</li>`).join("");
      const off   = r.enabled ? "" : " byte-routine-off";
      return `
        <li class="byte-routine${off}" data-routine-id="${r.id}">
          <div class="byte-routine-head">
            <button type="button" class="byte-routine-name" data-routine-rename title="Rename">${escapeHtml(r.name)}</button>
            <button type="button" class="byte-routine-toggle" data-routine-toggle aria-label="${r.enabled ? "Turn off" : "Turn on"}">${r.enabled ? "on" : "off"}</button>
            <button type="button" class="byte-routine-remove" data-routine-remove aria-label="Delete">×</button>
          </div>
          ${r.description ? `<p class="byte-routine-desc">${escapeHtml(r.description)}</p>` : ""}
          <ol class="byte-routine-steps">${steps}</ol>
        </li>
      `;
    }).join("");
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

  list.addEventListener("click", async (e) => {
    const routine = routineFor(e.target);
    if (!routine) return;

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
