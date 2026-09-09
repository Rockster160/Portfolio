// Drives the Byte actions menu — the header button that replaced the row of
// quick-action chips under the pet — and prints what was on screen at each
// step, as JSON for byte_actions_menu_spec.rb.
//
// The module is wired to real elements, so this builds just enough of one: a
// node knows its parent, its data attributes and its listeners, and `closest`
// walks up matching the handful of selector shapes hero.js actually asks for.
// Everything the module sends is recorded rather than performed.
import { initBuddyHero } from "../../app/javascript/src/pages/byte/buddy/hero.js";

// ---- the smallest DOM that answers what hero.js asks --------------------
function node(tag, { cls = "", data = {}, text = "" } = {}) {
  const el = {
    tag,
    className:   cls,
    dataset:     { ...data },
    hidden:      false,
    attrs:       {},
    children:    [],
    parent:      null,
    listeners:   {},
    textContent: text,
    title:       "",

    appendChild(child) {
      child.parent = el;
      el.children.push(child);
      return child;
    },
    addEventListener(name, fn) { el.listeners[name] = fn; },
    setAttribute(name, value) { el.attrs[name] = String(value); },
    getAttribute(name) { return el.attrs[name] ?? null; },

    matches(selector) {
      if (selector === el.tag) return true;
      if (selector.startsWith(".")) return el.className.split(/\s+/).includes(selector.slice(1));

      const pair = selector.match(/^\[data-([\w-]+)(?:="([^"]*)")?\]$/);
      if (!pair) return false;
      const key = pair[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      if (!(key in el.dataset)) return false;
      return pair[2] === undefined || el.dataset[key] === pair[2];
    },

    closest(selector) {
      let at = el;
      while (at) {
        if (at.matches(selector)) return at;
        at = at.parent;
      }
      return null;
    },

    contains(other) {
      let at = other;
      while (at) {
        if (at === el) return true;
        at = at.parent;
      }
      return false;
    },

    all() {
      return el.children.flatMap((c) => [c, ...c.all()]);
    },
    querySelector(selector)    { return el.all().find((c) => c.matches(selector)) || null; },
    querySelectorAll(selector) { return el.all().filter((c) => c.matches(selector)); },
  };

  // The removal openQuick does before refilling: setting text drops the rows.
  Object.defineProperty(el, "text", { get: () => el.textContent });
  return el;
}

// `textContent = "…"` has to wipe the children, or a reload of the routine
// panel stacks the new rows under the old ones and nothing ever shrinks.
function textNode(tag, opts) {
  const el = node(tag, opts);
  let text = el.textContent;
  Object.defineProperty(el, "textContent", {
    get: () => text,
    set: (value) => { text = String(value); el.children.length = 0; },
  });
  return el;
}

const documentListeners = {};
globalThis.document = {
  querySelector: () => null,
  addEventListener(name, fn) {
    (documentListeners[name] ||= []).push(fn);
  },
  createElement: (tag) => node(tag),
};

const requests = [];
let routinePayload = { routines: [{ id: 5, name: "Wind down", enabled: true, position: 0 }] };

globalThis.fetch = async (url, opts = {}) => {
  requests.push({ url, method: opts.method || "GET", body: opts.body ? JSON.parse(opts.body) : null });
  if (url === "/buddy/routines") {
    return { ok: true, json: async () => routinePayload };
  }
  return { ok: true, json: async () => ({}) };
};

// ---- the page, as show.html.erb builds it -------------------------------
const hero = node("section", { data: { buddyAwakeExpression: "neutral" } });
hero.appendChild(node("div", { cls: "byte-buddy-char" }));
hero.appendChild(node("div", { cls: "byte-buddy-face-popover", data: { buddyFacePopover: "" } }));

const menuToggle = node("button", { data: { byteActionsToggle: "" } });
const menu = node("div", { data: { byteActionsMenu: "" } });
menu.hidden = true;

const panels = {};
function panel(name) {
  const el = node("div", { cls: "byte-actions-panel", data: { actionsPanel: name } });
  el.hidden = name !== "root";
  menu.appendChild(el);
  panels[name] = el;
  return el;
}

const root = panel("root");
const rows = {};
["quick", "suggest", "stash", "checkin", "affirmation"].forEach((kind) => {
  rows[kind] = root.appendChild(node("button", { data: { buddyAction: kind } }));
});

const quickPanel = panel("quick");
const quickBack  = quickPanel.appendChild(node("button", { cls: "byte-actions-back", data: { actionsBack: "" } }));
const quickList  = quickPanel.appendChild(textNode("div", { cls: "byte-actions-list", data: { buddyQuickList: "" } }));

const suggestPanel = panel("suggest");
suggestPanel.appendChild(node("button", { cls: "byte-actions-back", data: { actionsBack: "" } }));
const suggestHome = suggestPanel.appendChild(node("button", { data: { suggest: "home" } }));

const stashPanel = panel("stash");
stashPanel.appendChild(node("button", { cls: "byte-actions-back", data: { actionsBack: "" } }));
const stashWork = stashPanel.appendChild(node("button", { data: { stash: "work" } }));

const checkinPanel = panel("checkin");
checkinPanel.appendChild(node("button", { cls: "byte-actions-back", data: { actionsBack: "" } }));
const moodLow = checkinPanel.appendChild(node("button", { data: { mood: "low" } }));

const elsewhere = node("div");

const stashed = [];
const buddy = initBuddyHero({
  hero,
  menu,
  menuToggle,
  conversationIdFn: () => 42,
  onStashArmed: (category) => stashed.push(category),
});

// ---- driving it ---------------------------------------------------------
const tapToggle  = () => menuToggle.listeners.click({ target: menuToggle });
const tap        = (target) => menu.listeners.click({ target });
const tapOutside = (target) => (documentListeners.click || []).forEach((fn) => fn({ target }));

const shown = () => (menu.hidden ? null : Object.keys(panels).find((n) => !panels[n].hidden) || null);
const state = () => ({ open: !menu.hidden, panel: shown(), expanded: menuToggle.getAttribute("aria-expanded") });

const out = {};

out.closed_at_boot = state();

tapToggle();
out.opened = state();

// A row that owns options REPLACES the list rather than stacking on it.
tap(rows.suggest);
out.into_suggest = { ...state(), root_hidden: root.hidden };

tap(suggestPanel.children[0]);
out.after_back = state();

tap(rows.suggest);
tap(suggestHome);
out.after_suggest = state();

// A tap inside is not a tap outside.
tapToggle();
tap(rows.stash);
tapOutside(stashWork);
out.inside_stays_open = state();

tap(stashWork);
out.after_stash = state();

// Reopening lands on the root, never on the panel the last tap left showing.
tapToggle();
out.reopened = state();

// Check-in, and the mood rides along to the server.
tap(rows.checkin);
tap(moodLow);
out.after_mood = state();

// A row with no options of its own acts and closes.
tapToggle();
tap(rows.affirmation);
out.after_affirmation = state();

// Outside closes; the toggle is not outside (its own handler already ran).
tapToggle();
tapOutside(elsewhere);
out.after_outside = state();

// Not a Buddy thread: no button, nothing open.
tapToggle();
buddy.onModeChange("claude");
out.non_buddy = { ...state(), toggle_hidden: menuToggle.hidden };
buddy.onModeChange("buddy");
out.back_to_buddy = { toggle_hidden: menuToggle.hidden };

// ---- the one panel filled from the server -------------------------------
(async () => {
  tapToggle();
  await Promise.resolve(rows.quick && tap(rows.quick));
  await new Promise((r) => setTimeout(r, 0));
  out.quick_loaded = {
    ...state(),
    rows: quickList.children.map((c) => ({ id: c.dataset.quickRoutine, label: c.textContent })),
  };

  tap(quickList.children[0]);
  out.after_routine = state();

  // Nothing saved: the panel says the thing that would produce one.
  routinePayload = { routines: [] };
  tapToggle();
  tap(rows.quick);
  await new Promise((r) => setTimeout(r, 0));
  out.quick_empty = { ...state(), text: quickList.textContent, rows: quickList.children.length };

  tap(quickBack);
  out.quick_back = state();

  out.armed = stashed;
  out.requests = requests;
  process.stdout.write(JSON.stringify(out, null, 2));
})();
