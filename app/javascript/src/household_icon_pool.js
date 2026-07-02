import { Monitor } from "./pages/dashboard/cells/monitor";

// Client-side registry of HouseholdIcons for the current user's household.
// Fed from /chores/icons.json, kept live via the "chores" MonitorChannel
// broadcast that HouseholdIconsController fires on create/update/destroy.
// Used by every markdown renderer that supports [hicon <name>] — dashboard
// cells, page markdown, quick-action widgets, etc.
class HouseholdIconPool {
  static #byName = new Map();
  static #loadPromise = null;
  static #signature = null;

  static normalize(name) {
    return String(name || "")
      .toLowerCase()
      .replace(/[\s_\-]+/g, " ")
      .trim();
  }

  static lookup(name) {
    return HouseholdIconPool.#byName.get(HouseholdIconPool.normalize(name)) || null;
  }

  static load() {
    if (HouseholdIconPool.#loadPromise) return HouseholdIconPool.#loadPromise;
    HouseholdIconPool.#loadPromise = Promise.all([
      HouseholdIconPool.#fetchJson("/chores/icons.json", []),
      HouseholdIconPool.#fetchJson("/chores/icons/signature", null),
    ])
      .then(([rows, sig]) => {
        HouseholdIconPool.#ingest(rows);
        HouseholdIconPool.#signature = sig;
      })
      .catch(() => { HouseholdIconPool.#ingest([]); });
    return HouseholdIconPool.#loadPromise;
  }

  static refresh() {
    HouseholdIconPool.#loadPromise = null;
    return HouseholdIconPool.load();
  }

  // Called on WS reconnect. Cheap — fetches only the {updated_at, count}
  // fingerprint. Refreshes the full pool iff the signature has changed
  // since we last synced. Catches the case where a create/update/delete
  // broadcast fired while this tab was disconnected.
  static async syncIfChanged() {
    const sig = await HouseholdIconPool.#fetchJson("/chores/icons/signature", null);
    if (!sig) return;
    if (HouseholdIconPool.#signature && HouseholdIconPool.#sigEqual(sig, HouseholdIconPool.#signature)) return;
    HouseholdIconPool.#signature = sig;
    return HouseholdIconPool.refresh();
  }

  static #sigEqual(a, b) {
    return a.updated_at === b.updated_at && a.count === b.count;
  }

  static #fetchJson(url, fallback) {
    return fetch(url, {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
      .then((r) => (r.ok ? r.json() : fallback))
      .catch(() => fallback);
  }

  static #ingest(rows) {
    const map = new Map();
    (rows || []).forEach((row) => {
      const rawName = row.n || row.name;
      const dataUrl = row.c || row.image_data;
      const key = HouseholdIconPool.normalize(rawName);
      if (!key || !dataUrl) return;
      map.set(key, { dataUrl: dataUrl, name: rawName });
    });
    HouseholdIconPool.#byName = map;
  }

  // Returns the <span><img></span> HTML for a name, or ❌ when the icon
  // isn't in the pool. Data URLs are quote-safe, so we only guard against
  // stray quotes in the name attribute.
  static markupHtml(name) {
    const icon = HouseholdIconPool.lookup(name);
    if (!icon) return "❌";
    const src = String(icon.dataUrl).replace(/"/g, "&quot;");
    const alt = String(icon.name || name).replace(/"/g, "&quot;");
    return '<span class="dashboard-img-wrapper hicon-wrapper"><img src="' + src + '" alt="' + alt + '"/></span>';
  }
}

if (typeof document !== "undefined") {
  if (document.readyState === "complete" || document.readyState === "interactive") {
    HouseholdIconPool.load();
  } else {
    document.addEventListener("DOMContentLoaded", () => HouseholdIconPool.load());
  }
}

Monitor.subscribe("chores", {
  connected: function () {
    // Catches any create/update/delete that landed while we were offline —
    // the live broadcast is missed on disconnected tabs.
    HouseholdIconPool.syncIfChanged();
  },
  received: function (payload) {
    const data = payload && payload.data;
    if (!data || data.reason !== "icons_changed") return;
    HouseholdIconPool.refresh();
  },
});

window.HouseholdIconPool = HouseholdIconPool;
export { HouseholdIconPool };
