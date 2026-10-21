// Buttons a Jil task put under a Buddy message (Buddy::MessageButtons) - each
// one fires a trigger. Waiting, they are a row of the app's ordinary action
// buttons; once the message is settled, by this press or anybody else's or by
// the thing happening on its own, the row gives way to what became of it.
//
// The action is an ordinary ByteAction, so the press is the ordinary decision
// POST, and the server 409s a second one once it stops being pending.
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

export function renderMessageButtons(container, message) {
  const meta = message.metadata || {};
  const requestId = meta.action_request_id;
  const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
  const spent = (meta.action_state || "pending") !== "pending";

  if (spent || !requestId || !buttons.length) {
    const outcome = spent ? meta.buttons_outcome : null;
    container.innerHTML = outcome
      ? `<div class="byte-msg-buttons-outcome">${escapeHtml(outcome)}</div>`
      : "";
    return;
  }

  container.innerHTML = `
    <div class="byte-action-buttons">
      ${buttons.map((button) => `
        <button type="button" class="${classesFor(button)}" data-button-id="${escapeHtml(button.id)}"
          ${button.color ? `style="--byte-btn-color: ${escapeHtml(button.color)}"` : ""}>
          <span class="byte-action-btn-label">${escapeHtml(button.label || "")}</span>
        </button>
      `).join("")}
    </div>
  `;

  const els = Array.from(container.querySelectorAll(".byte-action-btn"));
  els.forEach((el) => {
    el.addEventListener("click", async () => {
      // Every button locks before the request goes out: the round trip is
      // long enough to press a second one, and there is only one answer.
      els.forEach((other) => {
        other.disabled = true;
        other.classList.add("disabled");
      });
      try {
        await post(requestId, el.dataset.buttonId);
        // The server repaints this message as settled; nothing to do here.
      } catch (e) {
        console.warn("[byte] message button failed", e);
        els.forEach((other) => {
          other.disabled = false;
          other.classList.remove("disabled");
        });
      }
    });
  });
}

function classesFor(button) {
  const classes = ["byte-action-btn"];
  if (button.variant) classes.push(`byte-action-btn-${button.variant}`);
  if (button.color) classes.push("byte-action-btn-colored");
  return classes.join(" ");
}

function escapeHtml(str) {
  return String(str).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}
