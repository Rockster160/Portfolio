// HTTP layer with offline queue + CSRF refresh on 401/422. Every mutation
// goes through this — success returns the JSON, network/5xx failures enqueue
// to the offline queue so the page-script can flush on reconnect. A stale
// CSRF token (page open for hours, session rotated) triggers a single
// refresh + retry so clicks don't silently no-op.

import { enqueue, getTabId } from "./offline_queue";

let cachedToken = null;

function csrfMetaToken() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
}

async function refreshCsrf() {
  try {
    const res = await fetch("/timers/csrf", {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    if (!res.ok) return null;
    const j = await res.json();
    if (j?.token) {
      cachedToken = j.token;
      const meta = document.querySelector('meta[name="csrf-token"]');
      if (meta) meta.setAttribute("content", j.token);
      return j.token;
    }
  } catch (e) { /* ignore */ }
  return null;
}

function fetchWith(url, method, payload, token) {
  return fetch(url, {
    method,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      "Accept":       "application/json",
      "X-CSRF-Token": token,
    },
    body: method === "GET" ? null : JSON.stringify(payload),
  });
}

async function safeJson(res) {
  try { return await res.json(); } catch (e) { return null; }
}

async function request(url, { method = "POST", body = null, queueOnFail = true } = {}) {
  const payload = body ? { ...body, tab_id: getTabId() } : { tab_id: getTabId() };
  try {
    let token = cachedToken || csrfMetaToken();
    let res = await fetchWith(url, method, payload, token);

    // 401/422 is ambiguous: either a stale CSRF token (no JSON body) or
    // an actual validation failure (controller renders `{ errors: [...] }`).
    // Peek at the body — if it carries an `errors` array, surface it to
    // the caller WITHOUT a CSRF retry; the retry won't fix a validation
    // failure and just delays the error feedback.
    if (res.status === 401 || res.status === 422) {
      const body1 = await safeJson(res);
      if (body1 && Array.isArray(body1.errors) && body1.errors.length) {
        return { __error: body1.errors.join(", ") };
      }
      const fresh = await refreshCsrf();
      if (fresh) {
        res = await fetchWith(url, method, payload, fresh);
        if (res.ok) return res.status === 204 ? {} : await safeJson(res);
        if (res.status === 401 || res.status === 422) {
          const body2 = await safeJson(res);
          if (body2 && Array.isArray(body2.errors) && body2.errors.length) {
            return { __error: body2.errors.join(", ") };
          }
        }
        if (res.status >= 500 && queueOnFail) enqueue({ url, method, body: payload });
        return null;
      }
    }

    if (res.ok) return res.status === 204 ? {} : await safeJson(res);
    if (res.status >= 500 && queueOnFail) enqueue({ url, method, body: payload });
    return null;
  } catch (e) {
    if (queueOnFail) enqueue({ url, method, body: payload });
    return null;
  }
}

export const api = {
  create:    (attrs) => request("/timers/items", { body: { timer: attrs } }),
  update:    (id, attrs) => request(`/timers/items/${id}`, { method: "PATCH", body: { timer: attrs } }),
  destroy:   (id) => request(`/timers/items/${id}`, { method: "DELETE" }),
  start:     (id) => request(`/timers/items/${id}/start`),
  pause:     (id) => request(`/timers/items/${id}/pause`),
  resume:    (id) => request(`/timers/items/${id}/resume`),
  reset:     (id) => request(`/timers/items/${id}/reset`),
  confirm:   (id) => request(`/timers/items/${id}/confirm`),
  increment: (id, by) => request(`/timers/items/${id}/increment`, { body: { by } }),
  advance:   (id, by) => request(`/timers/items/${id}/advance`, { body: { by } }),
  layout:    (id, geom) => request(`/timers/items/${id}/layout`, { method: "PATCH", body: { timer: geom } }),
  reorder:   (ids) => request("/timers/order", { method: "PATCH", body: { ids } }),

  createQuick:  (attrs) => request("/timers/quick_buttons", { body: { timer_quick_button: attrs } }),
  updateQuick:  (id, attrs) => request(`/timers/quick_buttons/${id}`, { method: "PATCH", body: { timer_quick_button: attrs } }),
  destroyQuick: (id) => request(`/timers/quick_buttons/${id}`, { method: "DELETE" }),
  reorderQuick: (ids) => request("/timers/quick_buttons/order", { method: "PATCH", body: { ids } }),

  createPage:  (attrs) => request("/timers/pages", { body: { timer_page: attrs } }),
  updatePage:  (id, attrs) => request(`/timers/pages/${id}`, { method: "PATCH", body: { timer_page: attrs } }),
  destroyPage: (id) => request(`/timers/pages/${id}`, { method: "DELETE" }),

  createShare:  (attrs) => request("/timers/shares", { body: { timer_share_token: attrs }, queueOnFail: false }),
  updateShare:  (id, attrs) => request(`/timers/shares/${id}`, { method: "PATCH", body: { timer_share_token: attrs }, queueOnFail: false }),
  destroyShare: (id) => request(`/timers/shares/${id}`, { method: "DELETE", queueOnFail: false }),

  sync: async (since) => {
    const url = since ? `/timers/sync?since=${encodeURIComponent(since)}` : "/timers/sync";
    try {
      const res = await fetch(url, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return null;
      return await res.json();
    } catch (e) {
      return null;
    }
  },
};
