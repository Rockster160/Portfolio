import { Monitor } from "./pages/dashboard/cells/monitor";

// Client-side registry of HouseholdIcons for the current user's household.
// Fed from /chores/icons.json, kept live via the "chores" MonitorChannel
// broadcast that HouseholdIconsController fires on create/update/destroy.
// Used by every markdown renderer that supports [hicon <name>] — dashboard
// cells, page markdown, quick-action widgets, etc.
class HouseholdIconPool {
  static #byName = new Map();
  static #loadPromise = null;

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
    HouseholdIconPool.#loadPromise = fetch("/chores/icons.json", {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
      .then((r) => (r.ok ? r.json() : []))
      .then((rows) => HouseholdIconPool.#ingest(rows))
      .catch(() => { HouseholdIconPool.#ingest([]); });
    return HouseholdIconPool.#loadPromise;
  }

  static refresh() {
    HouseholdIconPool.#loadPromise = null;
    return HouseholdIconPool.load();
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
  received: function (payload) {
    const data = payload && payload.data;
    if (!data || data.reason !== "icons_changed") return;
    HouseholdIconPool.refresh();
  },
});

window.HouseholdIconPool = HouseholdIconPool;
export { HouseholdIconPool };
