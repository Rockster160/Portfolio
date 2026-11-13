// Quest board entry. Boots on /quests/:id (data-quests-root) and no-ops on every
// other page — this module is bundled into application.js.
//
// Tap a circle to count it, hold to undo the last thing done to it, ×N to
// count several at once. Edit mode shows every quest, on the board right now
// or not, to tap into the editor or drag into a new order or section. A
// rotation is drawn as a card below its section's circles instead of as one.
// Sections are drawn in the board's order (set in settings), with quests in no
// section above them all.

import QuestRules from "./rules";
import { createStore } from "./store";
import { setupEditModal } from "./edit_modal";
import QuestRotation from "./rotation";
import { createRotationCard } from "./rotation_card";
import { setupRotationModal } from "./rotation_modal";
import { renderIconValue, loadIconPool, onIconPoolChanged } from "../../icon_picker";

const LONG_MS = 550;
const MOVE_THRESHOLD = 8;
const TICK_MS = 30000;

function bootQuests(root) {
  const boardEl = root.querySelector("[data-quests-board]");
  const emptyEl = root.querySelector("[data-quests-empty]");
  const dayEl = root.querySelector("[data-quests-day]");
  const pendingEl = root.querySelector("[data-pending-hooks]");
  const connDot = root.querySelector("[data-conn-dot]");
  const flashEl = document.querySelector("[data-quests-flash]");
  const editBtn = root.querySelector("[data-edit-mode-toggle]");
  const multiBtn = root.querySelector("[data-multiplier-toggle]");
  const cardTemplate = root.querySelector('[data-template="quest-circle"]');

  const cards = new Map();
  const rotationCards = new Map();
  let editMode = false;
  let multiMode = false;
  let dragging = false;
  const sortables = new Map();
  let flashTimer = null;

  function flash(text, kind = "") {
    if (!flashEl) return;
    flashEl.textContent = text;
    flashEl.className = `chores-flash show ${kind}`.trim();
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => flashEl.classList.remove("show"), 2200);
  }

  const store = createStore({
    boardId:  root.dataset.boardId,
    onChange: () => render(),
    onError:  msg => flash(msg, "error"),
  });
  const board = () => store.board;
  const today = () => QuestRules.gameDate(new Date(), QuestRules.resetHourOf(board()));

  // Saves the board, first firing (or taking back) whatever a batch quest
  // finished (or undone) by the change does. `always: false` saves only when
  // a batch quest moved.
  function commit({ always = true } = {}) {
    const { fired, reversed } = QuestRules.settleAuto(board(), new Date());
    if (!always && !fired.length && !reversed.length) return;
    reversed.forEach(entry => { if (entry.hooks.length) store.reverseHooks(entry); });
    store.commit();
    fired.forEach(entry => { if (entry.hooks.length) store.fireHooks(entry); });
  }

  // ------------------------------------------------------------ rendering

  function buildCard(item) {
    const node = cardTemplate.content.firstElementChild.cloneNode(true);
    node.dataset.questId = item.id;
    return node;
  }

  function patchRing(node, item, count, target) {
    const ring = node.querySelector("[data-ring-progress]");
    if (!ring) return;
    if (target != null && target > 1) {
      // Multi-tap: the ring fills tap by tap and continues smoothly into
      // full, instead of the single-tap keyframe that draws it from empty.
      // A count-down quest's ring is what's left, draining toward empty.
      const done = Math.min(1, count / target);
      const pct = QuestRules.countsDown(item, target) ? 1 - done : done;
      ring.style.strokeDasharray = "100";
      ring.style.strokeDashoffset = String(100 - (pct * 100));
      ring.style.opacity = pct > 0 ? "1" : "0";
    } else {
      ring.style.strokeDasharray = "";
      ring.style.strokeDashoffset = "";
      ring.style.opacity = "";
    }
  }

  function patchCard(node, item, { visible, firstPaint }) {
    const b = board();
    const date = today();
    const target = QuestRules.resolveTarget(b, item, date);
    const count = QuestRules.countOf(b, item, date);
    const done = target != null && count >= target;
    const wasDone = node.classList.contains("done");
    // Glows whenever the count moves, whatever moved it — this circle's own
    // tap, another quest's effect, an undo, or a board pulled from another
    // device — so a change is easy to spot. Not on the first paint.
    if (!firstPaint && node.dataset.count !== String(count)) replay(node, "quests-glow");
    node.dataset.count = String(count);

    node.classList.toggle("done", done);
    node.classList.toggle("partial", !done && target != null && target > 1);
    // A quest already done when the page paints shows done without replaying
    // the celebration; one finished by this tap draws it.
    node.classList.toggle("no-animate", done && (firstPaint || wasDone || (target || 0) > 1));
    node.classList.toggle("pending", !visible);
    node.classList.toggle("secret", !!item.hidden);
    node.title = (
      item.hidden ? "Hidden — only shown while editing"
        : visible ? "" : "Not on the board right now"
    );
    patchRing(node, item, count, target);

    const icon = node.querySelector("[data-icon]");
    if (firstPaint || icon.dataset.value !== (item.icon || "")) paintIcon(icon, item.icon || "");

    const name = QuestRules.displayName(item, target);
    const titleEl = node.querySelector(".title");
    if (titleEl.textContent !== name) titleEl.textContent = name;

    const slot = node.querySelector("[data-count-slot]");
    const shown = QuestRules.shownCount(item, count, target);
    const text = (
      target == null ? String(count)
        : target > 1 ? `${shown}/${target}`
          : ""
    );
    let badge = slot.querySelector(".count-badge");
    if (!text) { badge?.remove(); return; }
    if (!badge) {
      badge = document.createElement("span");
      badge.className = "count-badge";
      slot.appendChild(badge);
    }
    if (badge.textContent !== text) badge.textContent = text;
  }

  // Restarts a one-shot animation class, even one still running.
  function replay(node, className) {
    node.classList.remove(className);
    void node.offsetWidth;
    node.classList.add(className);
  }
  boardEl.addEventListener("animationend", e => {
    const node = e.target.closest("[data-quest-id]");
    if (e.animationName === "quests-glow") node?.classList.remove("quests-glow");
  });

  function paintIcon(icon, value) {
    icon.dataset.value = value;
    renderIconValue(icon, value);
    if (icon.childNodes.length) return;
    const placeholder = document.createElement("span");
    placeholder.className = "icon-placeholder";
    placeholder.textContent = "🎯";
    icon.appendChild(placeholder);
  }

  // One <section> per section name, made once and kept.
  const sectionEls = new Map();
  function sectionFor(name) {
    let entry = sectionEls.get(name);
    if (entry) return entry;
    const section = document.createElement("section");
    section.className = "chores-section";
    if (name) {
      const h = document.createElement("h3");
      h.className = "chores-section-heading";
      h.textContent = name;
      section.appendChild(h);
    }
    const wrap = document.createElement("div");
    wrap.className = "chores-circles-wrap";
    const grid = document.createElement("div");
    grid.className = "chores-circles";
    grid.dataset.section = name;
    wrap.appendChild(grid);
    const rotations = document.createElement("div");
    rotations.className = "quests-rotations";
    section.append(wrap, rotations);
    entry = { section, grid, rotations };
    sectionEls.set(name, entry);
    return entry;
  }

  // Puts `nodes` into `parent` in that order, moving only what's out of place
  // and dropping whatever is left over, so a card keeps its element (and any
  // ring animation running in it) across every repaint.
  function placeInOrder(parent, nodes) {
    nodes.forEach((node, i) => {
      if (parent.children[i] !== node) parent.insertBefore(node, parent.children[i] || null);
    });
    while (parent.children.length > nodes.length) parent.lastElementChild.remove();
  }

  // In play only what's on the board right now is drawn; in edit mode
  // everything is, the rest dimmed and hidden quests dashed. A named section always shows, empty or
  // not; the unnamed one only when something is in it.
  function render() {
    if (dragging) return;
    const b = board();
    const now = new Date();
    const sections = new Map([["", []], ...QuestRules.sectionNames(b).map(n => [n, []])]);
    b.items.forEach(item => {
      const rotation = QuestRotation.isRotation(item);
      const visible = rotation || QuestRules.isVisible(b, item, now);
      if (!visible && !editMode) return;
      sections.get(item.section || "").push({ item, visible, rotation });
    });
    sections.forEach((entries, name) => {
      if (!entries.length && !name) sections.delete(name);
    });

    const seen = new Set();
    const sectionNodes = [];
    sections.forEach((entries, name) => {
      const { section, grid, rotations } = sectionFor(name);
      placeInOrder(rotations, entries.filter(e => e.rotation).map(({ item }) => {
        let card = rotationCards.get(item.id);
        if (!card) {
          card = createRotationCard({ item, getBoard: board, getToday: today, onToggle: pickOption, onEdit: rotationEditor.open });
          rotationCards.set(item.id, card);
        }
        card.render(item);
        seen.add(item.id);
        return card.node;
      }));
      const nodes = entries.filter(e => !e.rotation).map(({ item, visible }) => {
        let node = cards.get(item.id);
        const firstPaint = !node;
        if (!node) { node = buildCard(item); cards.set(item.id, node); }
        patchCard(node, item, { visible, firstPaint });
        seen.add(item.id);
        return node;
      });
      placeInOrder(grid, nodes);
      sectionNodes.push(section);
    });
    placeInOrder(boardEl, sectionNodes);
    sectionEls.forEach(({ grid }, name) => {
      if (sections.has(name)) return;
      sortables.get(grid)?.destroy();
      sortables.delete(grid);
      sectionEls.delete(name);
    });
    [...cards.keys()].forEach(id => { if (!seen.has(id)) cards.delete(id); });
    [...rotationCards.keys()].forEach(id => { if (!seen.has(id)) rotationCards.delete(id); });
    emptyEl.classList.toggle("hidden", [...sections.values()].some(entries => entries.length));

    const day = today().toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
    if (dayEl.textContent !== day) dayEl.textContent = day;
    const pending = store.pendingHooks;
    pendingEl.classList.toggle("hidden", !pending);
    pendingEl.textContent = `${pending} pending`;
    if (editMode) bindSortables();
  }

  // ------------------------------------------------------------ actions

  function itemFor(node) {
    return QuestRules.findItem(board(), node?.dataset.questId);
  }

  function complete(item, times = 1) {
    const entry = QuestRules.tap(board(), item, new Date(), times);
    if (!entry) {
      const node = cards.get(item.id);
      if (node) replay(node, "quests-bump");
      return;
    }
    navigator.vibrate?.(10);
    commit();
    if (entry.hooks.length) store.fireHooks(entry);
  }

  function pickOption(item, date, optionId) {
    if (!QuestRotation.toggle(board(), item, date, optionId)) return;
    navigator.vibrate?.(10);
    commit();
  }

  function undoLast(item) {
    const entry = QuestRules.undo(board(), item, new Date());
    if (!entry) { flash("Nothing to undo", "warn"); return; }
    navigator.vibrate?.([10, 40, 10]);
    if (entry.hooks.length) store.reverseHooks(entry);
    commit();
    flash(entry.reset ? "Reset undone" : "Undone");
  }

  // ------------------------------------------------------------ gestures

  const press = { pointerId: null, node: null, x: 0, y: 0, moved: false, fired: false, timer: null };
  function resetPress() {
    clearTimeout(press.timer);
    Object.assign(press, { pointerId: null, node: null, moved: false, fired: false, timer: null });
  }

  boardEl.addEventListener("pointerdown", e => {
    if (press.pointerId !== null) return;
    const node = e.target.closest("[data-quest-id]");
    if (!node) return;
    if (!editMode && !e.target.closest(".circle-inner")) return;
    Object.assign(press, { pointerId: e.pointerId, node, x: e.clientX, y: e.clientY, moved: false, fired: false });
    press.timer = setTimeout(() => {
      if (!press.node || press.moved || editMode) return;
      press.fired = true;
      const item = itemFor(press.node);
      if (item) undoLast(item);
    }, LONG_MS);
  });
  boardEl.addEventListener("pointermove", e => {
    if (press.pointerId !== e.pointerId) return;
    if (Math.hypot(e.clientX - press.x, e.clientY - press.y) > MOVE_THRESHOLD) {
      press.moved = true;
      clearTimeout(press.timer);
    }
  });
  boardEl.addEventListener("pointerup", e => {
    if (press.pointerId !== e.pointerId) return;
    const { node, moved, fired } = press;
    resetPress();
    if (!node || moved || fired) return;
    const item = itemFor(node);
    if (!item) return;
    if (editMode) { editor.open(item); return; }
    if (multiMode) { openMulti(item); return; }
    complete(item);
  });
  ["pointercancel", "pointerleave"].forEach(evt => {
    boardEl.addEventListener(evt, e => { if (press.pointerId === e.pointerId) resetPress(); });
  });
  boardEl.addEventListener("contextmenu", e => {
    const item = itemFor(e.target.closest("[data-quest-id]"));
    if (!item) return;
    e.preventDefault();
    editor.open(item);
  });

  // ------------------------------------------------------------ edit mode

  // One Sortable per section grid, all in one group so a card can be dragged
  // into another section.
  function bindSortables() {
    if (typeof window.Sortable === "undefined") return;
    sectionEls.forEach(({ grid }) => {
      if (sortables.has(grid)) return;
      sortables.set(grid, window.Sortable.create(grid, {
        group: "quests",
        animation: 150, ghostClass: "sortable-ghost", chosenClass: "sortable-chosen", dragClass: "sortable-drag",
        forceFallback: true, fallbackOnBody: true, fallbackTolerance: 0,
        delay: 150, delayOnTouchOnly: true, touchStartThreshold: 4,
        onStart: () => { dragging = true; },
        onEnd: persistOrder,
      }));
    });
  }
  function unbindSortables() {
    sortables.forEach(s => s.destroy());
    sortables.clear();
  }

  // Edit mode draws every quest, so the DOM holds the whole board: its order
  // is the new order, and the section a card was dropped into is its section.
  function persistOrder() {
    dragging = false;
    const b = board();
    const placed = [];
    boardEl.querySelectorAll(".chores-circles").forEach(grid => {
      grid.querySelectorAll("[data-quest-id]").forEach(node => {
        const item = QuestRules.findItem(b, node.dataset.questId);
        if (!item) return;
        item.section = grid.dataset.section || "";
        placed.push(item);
      });
    });
    const rest = b.items.filter(i => !placed.includes(i));
    b.items = [...placed, ...rest];
    commit();
  }

  function setEditMode(on) {
    editMode = on;
    if (on) setMultiMode(false);
    editBtn.classList.toggle("active", on);
    root.classList.toggle("edit-mode", on);
    if (!on) unbindSortables();
    render();
  }
  editBtn.addEventListener("click", () => setEditMode(!editMode));

  function saveItem(item, { isNew }) {
    const b = board();
    const index = b.items.findIndex(i => i.id === item.id);
    if (index >= 0) b.items[index] = item;
    else b.items.push(item);
    QuestRules.dropMissingVisitors(b);
    commit();
    if (isNew) flash("Added");
  }

  const rotationEditor = setupRotationModal({
    getBoard: board,
    onSave:   saveItem,
    onDelete(item) {
      const b = board();
      b.items = b.items.filter(i => i.id !== item.id);
      QuestRules.dropMissingVisitors(b);
      commit();
    },
  });

  const editor = setupEditModal({
    getBoard: board,
    onSave:   saveItem,
    onDelete(item) {
      const b = board();
      b.items = b.items.filter(i => i.id !== item.id);
      b.items.forEach(i => {
        if (i.target?.item === item.id) i.target = { mode: "fixed", value: 1 };
        i.conditions = (i.conditions || []).filter(c => c.item !== item.id);
        i.effects = (i.effects || []).filter(fx => fx.item !== item.id);
        if (QuestRules.isAuto(i)) {
          i.target.conditions = (i.target.conditions || []).filter(c => c.item !== item.id);
        }
      });
      commit();
    },
    onReset(item) {
      if (QuestRules.resetItem(board(), item, new Date())) {
        commit();
        flash("Reset — hold it to undo");
      }
    },
    onSetCount: setCount,
  });

  // A new quest started at a count was just announced as added.
  function setCount(item, shown, { isNew = false } = {}) {
    const current = QuestRules.findItem(board(), item.id) || item;
    if (!QuestRules.setCount(board(), current, new Date(), shown)) return;
    commit();
    if (!isNew) flash("Set — hold it to undo");
  }

  // A tap anywhere that isn't a visitor card's week or options folds its
  // options away. A scroll never makes a click, so it leaves them open.
  document.addEventListener("click", e => rotationCards.forEach(card => card.blur(e)));

  // ------------------------------------------------------------ modals

  function wireDismiss(modal, onClose) {
    modal.addEventListener("click", e => {
      if (e.target === modal || e.target.closest('[data-action="cancel"]')) onClose();
    });
  }

  // Quick add: Enter adds and clears for the next one.
  const quickModal = root.querySelector("[data-quick-modal]");
  const quickForm = quickModal.querySelector("[data-quick-form]");
  const quickName = quickModal.querySelector("[data-quick-name]");
  const closeQuick = () => quickModal.classList.add("hidden");
  wireDismiss(quickModal, closeQuick);

  function quickDraft() {
    const { name, target } = QuestRules.parseQuickAdd(quickName.value);
    return QuestRules.newItem({ name, target: { mode: "fixed", value: target } });
  }

  root.querySelector("[data-add-quest]").addEventListener("click", () => {
    quickName.value = "";
    quickModal.classList.remove("hidden");
    quickName.focus();
  });
  quickForm.addEventListener("submit", e => {
    e.preventDefault();
    if (!quickName.value.trim()) { quickName.focus(); return; }
    board().items.push(quickDraft());
    commit();
    flash("Added");
    quickName.value = "";
    quickName.focus();
  });
  quickModal.querySelector("[data-quick-advanced]").addEventListener("click", () => {
    const draft = quickDraft();
    closeQuick();
    editor.open(draft, { isNew: true });
  });
  quickModal.querySelector("[data-quick-rotation]").addEventListener("click", () => {
    const name = quickName.value.trim();
    closeQuick();
    rotationEditor.open(QuestRotation.newRotation({ name }), { isNew: true });
  });

  // ×N: the next tap asks how many.
  const multiModal = root.querySelector("[data-multi-modal]");
  const multiForm = multiModal.querySelector("[data-multi-form]");
  const multiCount = multiModal.querySelector("[data-multi-count]");
  const multiModes = multiModal.querySelector("[data-multi-mode]");
  let multiItem = null;
  let multiSet = false;

  // Add counts that many more; Set to puts the circle straight at that number.
  function setMultiSet(on) {
    multiSet = on;
    multiModes.querySelectorAll(".pill").forEach(p => {
      p.classList.toggle("active", (p.dataset.value === "set") === on);
    });
    multiModal.querySelector("[data-multi-quicks]").classList.toggle("hidden", on);
    multiCount.min = on ? "0" : "1";
    multiCount.placeholder = "Count";
    if (!on || !multiItem) return;
    const target = QuestRules.resolveTarget(board(), multiItem, today());
    const count = QuestRules.countOf(board(), multiItem, today());
    multiCount.placeholder = `Now ${QuestRules.shownCount(multiItem, count, target)}`;
  }
  multiModes.addEventListener("click", e => {
    const pill = e.target.closest(".pill");
    if (!pill) return;
    setMultiSet(pill.dataset.value === "set");
    multiCount.focus();
  });
  const closeMulti = () => { multiModal.classList.add("hidden"); multiItem = null; };
  wireDismiss(multiModal, closeMulti);

  function setMultiMode(on) {
    multiMode = on;
    multiBtn.classList.toggle("active", on);
  }
  multiBtn.addEventListener("click", () => {
    if (editMode) setEditMode(false);
    setMultiMode(!multiMode);
  });

  function openMulti(item) {
    if (QuestRules.isAuto(item)) { setMultiMode(false); complete(item); return; }
    multiItem = item;
    setMultiSet(false);
    multiModal.querySelector("[data-multi-title]").textContent = `How many — ${QuestRules.displayName(item, QuestRules.resolveTarget(board(), item, today()))}?`;
    multiCount.value = "";
    multiModal.classList.remove("hidden");
    multiCount.focus();
  }
  function submitMulti(n) {
    const item = multiItem;
    const set = multiSet;
    closeMulti();
    setMultiMode(false);
    if (!item || !Number.isFinite(n)) return;
    if (set) setCount(item, n);
    else if (n > 0) complete(item, n);
  }
  multiModal.querySelector("[data-multi-quicks]").addEventListener("click", e => {
    const pill = e.target.closest(".pill");
    if (pill) submitMulti(parseInt(pill.dataset.value, 10));
  });
  multiForm.addEventListener("submit", e => {
    e.preventDefault();
    submitMulti(parseInt(multiCount.value, 10));
  });

  // Board settings. The reset hour lives in the board blob; the name is the
  // server's, since it's what the board list shows.
  const settingsModal = root.querySelector("[data-settings-modal]");
  const resetHourSelect = settingsModal.querySelector("[data-settings-reset-hour]");
  const nameInput = settingsModal.querySelector("[data-settings-name]");
  const nameEl = root.querySelector("[data-quests-name]");
  const boardPath = `/quests/${root.dataset.boardId}`;
  const closeSettings = () => settingsModal.classList.add("hidden");
  wireDismiss(settingsModal, closeSettings);
  // Sections: rename in place, × to remove, drag the handle to reorder.
  const sectionRows = settingsModal.querySelector("[data-settings-sections]");
  const newSectionInput = settingsModal.querySelector("[data-settings-new-section]");
  const sectionTemplate = settingsModal.querySelector('[data-template="section-row"]');
  let sectionSortable = null;

  function sectionRow({ id, name }) {
    const row = sectionTemplate.content.firstElementChild.cloneNode(true);
    row.dataset.sectionId = id || "";
    row.querySelector("input").value = name;
    return row;
  }

  function addSectionFromInput() {
    const name = newSectionInput.value.trim();
    if (!name) return;
    sectionRows.appendChild(sectionRow({ id: "", name }));
    newSectionInput.value = "";
  }
  settingsModal.querySelector("[data-settings-add-section]").addEventListener("click", () => {
    addSectionFromInput();
    newSectionInput.focus();
  });
  newSectionInput.addEventListener("keydown", e => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    addSectionFromInput();
  });
  sectionRows.addEventListener("click", e => {
    e.target.closest("[data-remove-section]")?.closest("[data-section-id]")?.remove();
  });

  root.querySelector("[data-settings-open]").addEventListener("click", () => {
    resetHourSelect.value = String(QuestRules.resetHourOf(board()));
    nameInput.value = nameEl.textContent.trim();
    QuestRules.syncSections(board());
    sectionRows.replaceChildren(...board().sections.map(sectionRow));
    newSectionInput.value = "";
    if (!sectionSortable && typeof window.Sortable !== "undefined") {
      sectionSortable = window.Sortable.create(sectionRows, {
        handle: "[data-section-handle]", animation: 150, forceFallback: true, fallbackOnBody: true,
      });
    }
    settingsModal.classList.remove("hidden");
  });
  settingsModal.querySelector("[data-settings-form]").addEventListener("submit", e => {
    e.preventDefault();
    const name = nameInput.value.trim();
    if (!name) { nameInput.focus(); return; }
    board().settings = { ...(board().settings || {}), resetHour: parseInt(resetHourSelect.value, 10) };
    addSectionFromInput();
    QuestRules.setSections(board(), Array.from(sectionRows.children).map(row => ({
      id:   row.dataset.sectionId,
      name: row.querySelector("input").value,
    })));
    commit();
    closeSettings();
    if (name !== nameEl.textContent.trim()) rename(name);
  });

  async function rename(name) {
    const res = await boardRequest("PATCH", { name });
    if (!res?.ok) { flash("Couldn't rename the board", "error"); return; }
    nameEl.textContent = name;
    document.title = name;
  }

  settingsModal.querySelector("[data-settings-delete]").addEventListener("click", async () => {
    if (!window.confirm(`Delete "${nameEl.textContent.trim()}" and every quest on it?`)) return;
    const res = await boardRequest("DELETE");
    if (!res?.ok) { flash("Couldn't delete the board", "error"); return; }
    window.location.href = "/quests";
  });

  function boardRequest(method, body) {
    return fetch(boardPath, {
      method,
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept:         "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    }).catch(() => null);
  }

  // ------------------------------------------------------------ liveness

  function syncConn() {
    connDot?.classList.toggle("offline", !navigator.onLine);
    if (connDot) connDot.title = navigator.onLine ? "Online" : "Offline";
  }
  window.addEventListener("online", syncConn);
  window.addEventListener("offline", syncConn);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    store.pull();
    store.flush();
    commit({ always: false });
    render();
  });
  // Time windows open and close, and the day rolls over, with nobody tapping
  // (a batch quest reading yesterday can finish on its own).
  setInterval(() => { commit({ always: false }); render(); }, TICK_MS);

  // A `hicon:` icon is a pointer into the household's uploads; repaint the
  // circles once those are known, and whenever they change.
  const repaintIcons = () => cards.forEach(node => {
    const icon = node.querySelector("[data-icon]");
    paintIcon(icon, icon.dataset.value || "");
  });
  loadIconPool().then(repaintIcons);
  onIconPoolChanged(repaintIcons);

  syncConn();
  commit({ always: false });
  render();
  store.pull();
  store.flush();
}

function boot() {
  const root = document.querySelector("[data-quests-root]");
  if (root && !root.dataset.booted) {
    root.dataset.booted = "1";
    bootQuests(root);
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
