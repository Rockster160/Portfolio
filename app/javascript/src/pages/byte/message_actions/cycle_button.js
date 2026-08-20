// One button under a message, for a work/break block (Buddy::TimerCycle).
//
// Deliberately not the multi-select renderer. That one is a checkbox LIST whose
// model is "tick the proposals you want run", with per-row status glyphs and an
// incremental POST of every checked id — none of which fits a single "start the
// next 30 minutes". Bending it to a one-row checklist would have made the
// commonest thing in the thread read as a form to fill in.
//
// The action is an ordinary ByteAction, so the tap is the ordinary decision
// POST. That's also what makes a second tap impossible: the server 409s once
// the action stops being pending, and the button locks the moment it's pressed.
async function post(requestId, value) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const res = await fetch(
    `/byte/actions/${encodeURIComponent(requestId)}/respond`,
    {
      method:      "POST",
      credentials: "same-origin",
      headers:     {
        "Content-Type": "application/json",
        "Accept":       "application/json",
        "X-CSRF-Token": csrfMeta ? csrfMeta.getAttribute("content") : "",
      },
      body: JSON.stringify({ value }),
    },
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json().catch(() => ({}));
}

export function renderCycleButton(container, message) {
  const meta = message.metadata || {};
  const requestId = meta.action_request_id;
  const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
  const button = buttons[0];
  if (!requestId || !button) {
    container.innerHTML = "";
    return;
  }

  // `decided` covers both the tap that started the next block and a card the
  // demo (or a later run) took down. Either way it's spent, and a spent button
  // that still looks pressable is an invitation to a 409.
  const spent = (meta.action_state || "pending") !== "pending";
  const label = button.label || "Start the next one";

  // `byte-action-btn` and its primary variant are the app's existing action
  // button, already styled for this exact job. A bespoke class here would be a
  // second look for the same thing.
  container.innerHTML = `
    <div class="byte-action-buttons">
      <button type="button" class="byte-action-btn byte-action-btn-primary${spent ? " disabled" : ""}" ${spent ? "disabled" : ""}>
        <span class="byte-action-btn-label">${spent ? "Started ✓" : escapeHtml(label)}</span>
      </button>
    </div>
  `;

  if (spent) return;

  const el = container.querySelector(".byte-action-btn");
  const text = el.querySelector(".byte-action-btn-label");
  el.addEventListener("click", async () => {
    // Locked before the request goes out, not after it comes back. The server
    // starts a real countdown on this, and the round trip is long enough to
    // double-tap through.
    el.disabled = true;
    el.classList.add("disabled");
    text.textContent = "Starting…";
    try {
      await post(requestId, button.value ?? label);
      // The new block's receipt arrives as its own message and the server
      // broadcast repaints this one as decided; nothing to do here.
    } catch (e) {
      console.warn("[byte] block start failed", e);
      el.disabled = false;
      el.classList.remove("disabled");
      text.textContent = label;
    }
  });
}

function escapeHtml(str) {
  return String(str).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}
