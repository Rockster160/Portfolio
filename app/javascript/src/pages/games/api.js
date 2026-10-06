function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
}

async function json(url, opts = {}) {
  const res = await fetch(url, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken(), ...(opts.headers || {}) },
    ...opts,
  });
  if (!res.ok) throw new Error(`${opts.method || "GET"} ${url} -> ${res.status}`);
  return res.json();
}

export const api = {
  csrfToken,
  playerColors: () => json("/games/player_colors"),
  upsertTemplate: (data) => json("/games/templates", { method: "POST", body: JSON.stringify(data) }),
};
