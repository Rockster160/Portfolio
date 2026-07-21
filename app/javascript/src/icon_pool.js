import { Monitor } from "./pages/dashboard/cells/monitor";

// ============================================================================
// Shared client-side IconPool — unified emoji + Tabler + household-custom
// registry. Mirrors `app/service/icon_pool.rb` (Ruby) — scoring, variant
// expansion, and normalization must stay in sync. If you change any of
// scoring tiers, query passes, normalization, variants, IRREGULARS, or
// STOPWORDS here, port the same change to the Ruby module in the same
// commit. Both consume `public/emoji_index.json`, `public/icons_index.json`,
// and `/chores/icons.json`.
//
// Consumers today:
//   * chores modal picker (`app/views/chores/_page_script.html.erb`)
//   * inline emoji autocomplete (`app/javascript/src/emoji_autocomplete.js`)
// ============================================================================

const IconPool = (function () {
  let GLOBAL_POOL = null;     // emoji + ti, fetched once per page
  let CUSTOM_POOL = [];       // per-household, refreshable on upload/delete
  let loadPromise = null;
  let customSignature = null; // {updated_at, count} — reconnect check
  const customListeners = [];

  async function fetchJson(url) {
    // Explicit Accept: application/json so the chores SW JSON-cache
    // branch actually persists the response — otherwise the picker pool
    // (including custom icons) wouldn't be available offline.
    try {
      const res = await fetch(url, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      return res.ok ? await res.json() : [];
    } catch (_e) {
      return [];
    }
  }

  function tag(arr, kind) {
    return arr.map((r) => ({ c: r.c, n: r.n, k: r.k, _kind: kind, _id: r.id }));
  }

  async function load() {
    if (!loadPromise) {
      loadPromise = (async () => {
        const [emoji, icons, custom, sig] = await Promise.all([
          fetchJson("/emoji_index.json"),
          fetchJson("/icons_index.json"),
          fetchJson("/chores/icons.json"),
          fetchJson("/chores/icons/signature"),
        ]);
        CUSTOM_POOL = tag(custom, "custom");
        customSignature = sig && !Array.isArray(sig) ? sig : null;
        GLOBAL_POOL = tag(emoji, "emoji").concat(tag(icons, "ti"));
      })();
    }
    await loadPromise;
    return composite();
  }

  // Custom icons first (user's uploads win ties), then emoji, then ti.
  // Recomputed each call so refreshCustom() reflects immediately.
  function composite() {
    return CUSTOM_POOL.concat(GLOBAL_POOL || []);
  }

  async function refreshCustom() {
    const [fresh, sig] = await Promise.all([
      fetchJson("/chores/icons.json"),
      fetchJson("/chores/icons/signature"),
    ]);
    CUSTOM_POOL = tag(fresh, "custom");
    customSignature = sig && !Array.isArray(sig) ? sig : customSignature;
    customListeners.forEach((fn) => { try { fn(); } catch (_e) { /* noop */ } });
  }

  function onCustomChanged(fn) { customListeners.push(fn); }

  async function syncCustomIfChanged() {
    const sig = await fetchJson("/chores/icons/signature");
    if (!sig || Array.isArray(sig)) return;
    if (customSignature
      && sig.updated_at === customSignature.updated_at
      && sig.count === customSignature.count) return;
    await refreshCustom();
  }

  function normalize(q) {
    return (q || "").toLowerCase().replace(/[\s\-_:]+/g, "");
  }

  const IRREGULARS = {
    teeth: "tooth", mice: "mouse", geese: "goose", feet: "foot",
    knives: "knife", leaves: "leaf", lives: "life", loaves: "loaf",
    wolves: "wolf", shelves: "shelf", men: "man", women: "woman",
    children: "child", oxen: "ox", people: "person", cacti: "cactus",
  };
  const IRREGULAR_INV = Object.fromEntries(
    Object.entries(IRREGULARS).map(([k, v]) => [v, k]),
  );

  function variants(q) {
    const set = new Set([q]);
    if (IRREGULARS[q]) set.add(IRREGULARS[q]);
    if (IRREGULAR_INV[q]) set.add(IRREGULAR_INV[q]);

    if (q.endsWith("ies") && q.length > 4) set.add(q.slice(0, -3) + "y");
    if (q.endsWith("es")  && q.length > 3) set.add(q.slice(0, -2));
    if (q.endsWith("s")   && q.length > 2) set.add(q.slice(0, -1));
    if (q.length >= 3) { set.add(q + "s"); set.add(q + "es"); }

    if (q.endsWith("ing") && q.length > 4) {
      const base = q.slice(0, -3);
      set.add(base);
      set.add(base + "e");
    }
    if (q.endsWith("ed") && q.length > 3) {
      set.add(q.slice(0, -2));
      set.add(q.slice(0, -1));
    }
    if (q.length >= 3) {
      set.add(q + "ing");
      if (q.endsWith("e")) set.add(q.slice(0, -1) + "ing");
      set.add(q + "ed");
      if (q.endsWith("e")) set.add(q + "d");
    }

    return [...set];
  }

  function scoreOne(name, keys, q) {
    if (name === q) return 5.5;
    let best = 0;
    if (name.startsWith(q))     best = 3.5;
    else if (name.includes(q))  best = 2.5;
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const pos = 0.49 / (1 + i);
      if (k === q) {
        const v = 4 + pos;
        return v > best ? v : best;
      }
      if (k.startsWith(q)) {
        const v = 3 + pos;
        if (v > best) best = v;
      } else if (k.includes(q)) {
        const v = 2 + pos;
        if (v > best) best = v;
      }
    }
    return best;
  }

  function scoreRow(row, queryVariants) {
    const name = normalize(row.n);
    if (!row._nk) row._nk = (row.k || []).map(normalize);
    let best = 0;
    for (let i = 0; i < queryVariants.length; i++) {
      const s = scoreOne(name, row._nk, queryVariants[i]);
      if (s > best) best = s;
      if (best >= 5.5) break;
    }
    return best;
  }

  const STOPWORDS = new Set([
    "the", "a", "an", "and", "or", "to", "of", "in", "on", "at",
    "for", "with", "from", "by", "is", "are", "was", "were", "be",
    "do", "does", "did", "out", "off", "up", "down",
    "my", "your", "our", "this", "that", "these", "those",
  ]);

  function queryPasses(query) {
    const raw = (query || "").toLowerCase().trim();
    if (!raw) return [];
    const full = normalize(raw);
    const tokens = raw.split(/[^a-z0-9]+/).filter((t) => t && !STOPWORDS.has(t));
    const fullWeight = Math.max(1, tokens.length);
    const passes = [];
    if (full.length >= 2) passes.push([full, fullWeight]);
    tokens.forEach((t, i) => {
      if (t.length < 2 || t === full) return;
      passes.push([t, i + 1]);
    });
    return passes;
  }

  function expandPasses(passes) {
    return passes.map(([p, w]) => [variants(p), w]);
  }

  function sumScore(row, variantSetsWithWeights) {
    let total = 0;
    for (let j = 0; j < variantSetsWithWeights.length; j++) {
      const [vs, w] = variantSetsWithWeights[j];
      total += w * scoreRow(row, vs);
    }
    return total;
  }

  // Score-sorted search. Empty query returns pool in native (emoji-first)
  // order — caller can .slice(0, N) for a "show everything" view.
  async function search(query, { limit = Infinity } = {}) {
    const pool = await load();
    const passes = queryPasses(query);
    if (passes.length === 0) {
      return limit === Infinity ? pool.slice() : pool.slice(0, limit);
    }
    const variantSets = expandPasses(passes);
    const scored = [];
    for (let i = 0; i < pool.length; i++) {
      const total = sumScore(pool[i], variantSets);
      if (total > 0) scored.push([total, i, pool[i]]);
    }
    scored.sort((a, b) => b[0] - a[0] || a[1] - b[1]);
    return (limit === Infinity ? scored : scored.slice(0, limit)).map((t) => t[2]);
  }

  // Highest-scoring candidate. Floor at 3 (one prefix match) so we
  // don't auto-fill on a lone substring hit.
  async function bestMatch(query) {
    const pool = await load();
    const passes = queryPasses(query);
    if (passes.length === 0) return null;
    const variantSets = expandPasses(passes);
    let bestRow = null;
    let bestScore = 0;
    for (let i = 0; i < pool.length; i++) {
      const total = sumScore(pool[i], variantSets);
      if (total > bestScore) { bestScore = total; bestRow = pool[i]; }
    }
    return bestScore >= 3 ? bestRow : null;
  }

  // Data URL for a hicon:<id> reference — "" when the id isn't in the
  // already-loaded pool (deleted or still loading).
  function customSrcById(id) {
    const key = String(id);
    const row = CUSTOM_POOL.find((r) => String(r._id) === key);
    return row?.c || "";
  }

  return {
    load, normalize, variants, scoreRow, search, bestMatch,
    refreshCustom, syncCustomIfChanged, onCustomChanged, customSrcById,
  };
})();

// Reconnect check for tabs that were disconnected while an icon
// create/update/delete broadcast fired.
Monitor.subscribe("chores", {
  connected: function () { IconPool.syncCustomIfChanged(); },
  received: function (payload) {
    const data = payload && payload.data;
    if (!data || data.reason !== "icons_changed") return;
    IconPool.refreshCustom();
  },
});

window.IconPool = IconPool;
export { IconPool };
