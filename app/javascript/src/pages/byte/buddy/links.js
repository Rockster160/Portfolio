// The links manager: which records follow which, and whether any of them are
// pointing at nothing.
//
// Read and adjust only. Creating a link is a conversation with Byte, because
// picking two endpoints out of four kinds with the right cascade direction is
// a conversation and a bad form. What this panel is FOR is that a link used to
// be a Hash literal inside a Jil task — invisible unless you went looking in
// the editor — and a broken one was invisible full stop, because a link that
// matches nothing looks exactly like one whose condition hasn't happened.

async function apiCall(url, method, body) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-CSRF-Token": csrfMeta ? csrfMeta.getAttribute("content") : "",
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

function esc(str) {
  return String(str == null ? "" : str).replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}

const KIND_ICON = {
  event: "📋",
  chore: "🧹",
  agenda: "📅",
  list_item: "📝",
};

export function initBuddyLinks(root) {
  const list = root.querySelector("[data-byte-link-list]");
  const empty = root.querySelector("[data-byte-links-empty]");
  const count = document.querySelector("[data-byte-links-count]");
  if (!list) return null;

  let links = [];
  let matches = ["exactly", "starts_with", "contains"];

  function matchOptions(selected) {
    return matches
      .map(
        (m) =>
          `<option value="${esc(m)}"${m === selected ? " selected" : ""}>${esc(
            { exactly: "is exactly", starts_with: "starts with", contains: "contains" }[m] || m,
          )}</option>`,
      )
      .join("");
  }

  function render() {
    if (count) count.textContent = links.length ? String(links.length) : "";
    if (empty) empty.hidden = links.length > 0;

    list.innerHTML = links
      .map((l) => {
        // A broken end is the headline, not a footnote: it's the difference
        // between a rule that works and one that has silently never run.
        const broken = (l.broken || []).length
          ? `<p class="byte-link-broken">⚠ ${esc(l.broken.join("; "))}</p>`
          : "";
        const scopeRow = l.source.scope
          ? `<label class="byte-link-field">
               <span>notes</span>
               <select data-link-field="source_scope_match">${matchOptions(l.source.scope_match)}</select>
               <input type="text" data-link-field="source_scope" value="${esc(l.source.scope)}">
             </label>`
          : "";

        return `
          <li class="byte-link-row${l.enabled ? "" : " is-off"}${(l.broken || []).length ? " is-broken" : ""}" data-link-id="${l.id}">
            <div class="byte-link-head">
              <span class="byte-link-flow">
                ${KIND_ICON[l.source.kind] || ""} ${esc(l.source.name)}
                <span class="byte-link-arrow" aria-hidden="true">→</span>
                ${KIND_ICON[l.target.kind] || ""} ${esc(l.target.name)}${
                  l.target.scope ? ` <span class="byte-link-scope">${esc(l.target.scope)}</span>` : ""
                }
              </span>
              <label class="byte-link-toggle" title="${l.enabled ? "On" : "Off"}">
                <input type="checkbox" data-link-enabled${l.enabled ? " checked" : ""}>
              </label>
            </div>
            <p class="byte-link-sentence">${esc(l.sentence)}</p>
            ${broken}
            <div class="byte-link-fields">
              <label class="byte-link-field">
                <span>name</span>
                <select data-link-field="source_name_match">${matchOptions(l.source.name_match)}</select>
                <input type="text" data-link-field="source_name" value="${esc(l.source.name)}">
              </label>
              ${scopeRow}
            </div>
            <div class="byte-link-actions">
              ${
                l.target.kind === "chore"
                  ? `<label class="byte-link-ask"><input type="checkbox" data-link-ask${
                      l.ask_who ? " checked" : ""
                    }> ask who did it</label>`
                  : "<span></span>"
              }
              <button type="button" class="byte-link-remove" data-link-remove>Remove</button>
            </div>
          </li>`;
      })
      .join("");
  }

  async function save(id, body) {
    try {
      const updated = await apiCall(`/buddy/links/${id}`, "PATCH", body);
      links = links.map((l) => (l.id === updated.id ? updated : l));
      render();
    } catch (err) {
      window.alert((err.errors && err.errors.join("\n")) || "Couldn't save that link.");
      refresh();
    }
  }

  list.addEventListener("change", (e) => {
    const row = e.target.closest("[data-link-id]");
    if (!row) return;
    const id = Number(row.dataset.linkId);

    if (e.target.matches("[data-link-enabled]")) return save(id, { enabled: e.target.checked });
    if (e.target.matches("[data-link-ask]")) return save(id, { ask_who: e.target.checked });

    const field = e.target.dataset.linkField;
    if (field) save(id, { [field]: e.target.value });
  });

  list.addEventListener("click", async (e) => {
    if (!e.target.matches("[data-link-remove]")) return;
    const row = e.target.closest("[data-link-id]");
    if (!row) return;
    const link = links.find((l) => l.id === Number(row.dataset.linkId));
    if (!window.confirm(`Remove this link?\n\n${link ? link.sentence : ""}`)) return;

    await apiCall(`/buddy/links/${row.dataset.linkId}`, "DELETE");
    refresh();
  });

  async function refresh() {
    try {
      const data = await apiCall("/buddy/links", "GET");
      links = data.links || [];
      if (Array.isArray(data.matches) && data.matches.length) matches = data.matches;
      render();
    } catch (e) {}
  }

  refresh();
  return { refresh };
}
