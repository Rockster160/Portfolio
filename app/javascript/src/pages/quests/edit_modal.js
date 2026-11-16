// The full quest editor: name and count up top, everything else — section,
// step, schedule, conditions, effects on other quests, hooks — folded under
// one disclosure that opens by itself when the quest already uses any of it.

import QuestRules from "./rules";
import { bindIconStack } from "../../icon_stack";
import { createSearchPicker } from "../../prompt_search";

const CONDITION_OPS = [
  ["done", "is done"], ["not_done", "isn't done"],
  [">", "more than"], [">=", "at least"], ["=", "exactly"],
  ["<=", "at most"], ["<", "fewer than"], ["!=", "not"],
];
const VISITOR_OPS = [["here", "is here"], ["not_here", "isn't here"]];

// A rotation's option is picked as "rotationId/optionId", under its rotation's
// name, so the same row can name a quest or a visitor.
const OPTION_SEP = "/";

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => {
    if (k === "text") node.textContent = v;
    else if (k === "dataset") Object.assign(node.dataset, v);
    else node.setAttribute(k, v);
  });
  children.forEach(c => node.appendChild(typeof c === "string" ? document.createTextNode(c) : c));
  return node;
}

function select(key, options, value) {
  const node = el("select", { "data-k": key });
  options.forEach(([v, label]) => node.appendChild(el("option", { value: v, text: label })));
  if (value != null && options.some(([v]) => String(v) === String(value))) node.value = String(value);
  return node;
}

export function setupEditModal({ getBoard, onSave, onDelete, onReset, onSetCount }) {
  const modal = document.querySelector("[data-edit-modal]");
  const form = modal.querySelector("[data-edit-form]");
  const title = modal.querySelector("[data-edit-title]");
  const advanced = modal.querySelector("[data-advanced]");
  const deleteBtn = modal.querySelector("[data-edit-delete]");
  const resetBtn = modal.querySelector("[data-edit-reset]");
  const iconStack = modal.querySelector("[data-icon-stack]");
  bindIconStack(iconStack);
  let editing = null;
  let isNew = false;
  let shownCount = "";

  const field = name => form.querySelector(`[data-field="${name}"]`);

  function itemOptions() {
    const board = getBoard();
    const date = QuestRules.gameDate(new Date(), QuestRules.resetHourOf(board));
    return board.items.filter(i => i.id !== editing?.id && i.kind !== "rotation").map(i => {
      const title = QuestRules.displayName(i, QuestRules.resolveTarget(board, i, date)) || "(unnamed)";
      return { id: i.id, title, icon: i.icon };
    });
  }

  // Every rotation's options, under the rotation's name, for "Only when".
  function visitorOptions() {
    return getBoard().items.filter(i => i.kind === "rotation" && i.options?.length).flatMap(rotation => {
      return rotation.options.map(o => ({
        id:      `${rotation.id}${OPTION_SEP}${o.id}`,
        title:   o.name || "(unnamed)",
        icon:    o.icon,
        section: rotation.name || "Rotation",
      }));
    });
  }

  // The quest search, holding its pick in a hidden field named `key` so the
  // row reads it like any other, and announcing a new pick as its `change`.
  function questPicker(attrs, options, value) {
    const input = el("input", { type: "hidden", ...attrs, value: value || "" });
    const picker = createSearchPicker({
      config:   { options, placeholder: "Search quests…" },
      value:    value ? { id: value } : null,
      onChange: pick => {
        input.value = pick?.id ?? "";
        input.dispatchEvent(new Event("change"));
      },
    });
    return { input, node: el("div", { class: "quests-pick" }, [input, picker]) };
  }

  // ---- pills (one choice) and chips (any number of choices)
  function setPills(name, value) {
    form.querySelectorAll(`[data-pills="${name}"] .pill`).forEach(p => {
      p.classList.toggle("active", p.dataset.value === value);
    });
    syncShowFor();
  }
  function getPills(name) {
    return form.querySelector(`[data-pills="${name}"] .pill.active`)?.dataset.value || "";
  }
  function setChips(name, values) {
    form.querySelectorAll(`[data-chips="${name}"] .pill`).forEach(p => {
      p.classList.toggle("active", values.includes(parseInt(p.dataset.value, 10)));
    });
  }
  function getChips(name) {
    return Array.from(form.querySelectorAll(`[data-chips="${name}"] .pill.active`)).map(p => parseInt(p.dataset.value, 10));
  }
  function syncShowFor() {
    form.querySelectorAll("[data-show-for]").forEach(node => {
      const [name, value] = node.dataset.showFor.split(":");
      node.classList.toggle("hidden", getPills(name) !== value);
    });
    form.querySelectorAll("[data-hide-for]").forEach(node => {
      const [name, value] = node.dataset.hideFor.split(":");
      node.classList.toggle("hidden", getPills(name) === value);
    });
    syncCountNow();
    syncAutoMatch();
  }

  form.addEventListener("click", e => {
    const pill = e.target.closest("[data-pills] .pill");
    if (pill) { setPills(pill.closest("[data-pills]").dataset.pills, pill.dataset.value); return; }
    const chip = e.target.closest("[data-chips] .pill");
    if (chip) { chip.classList.toggle("active"); return; }
    const add = e.target.closest("[data-add-row]");
    if (add) { addRow(add.dataset.addRow, {}); return; }
    const remove = e.target.closest("[data-remove-row]");
    if (remove) remove.closest(".quests-row")?.remove();
  });

  // A batch quest counts itself. A new one starts at what's typed, or at 0.
  function syncCountNow() {
    const row = form.querySelector("[data-count-now]");
    row?.classList.toggle("hidden", getPills("target_mode") === "auto");
  }
  function syncAutoMatch() {
    const n = field("auto_n");
    n?.classList.toggle("hidden", field("auto_match")?.value !== "atLeast");
  }
  field("auto_match").addEventListener("change", syncAutoMatch);

  // ---- repeating rows
  const rowBuilders = {
    conditions(c) {
      const value = el("input", { type: "number", "data-k": "value", class: "quests-num", value: c.value ?? 0 });
      const current = c.option ? `${c.item}${OPTION_SEP}${c.option}` : c.item;
      const { input: item, node: itemPicker } = questPicker(
        { "data-k": "item" }, [...itemOptions(), ...visitorOptions()], current,
      );
      const op = el("select", { "data-k": "op" });
      let shownOps = null;
      const sync = () => {
        const ops = item.value.includes(OPTION_SEP) ? VISITOR_OPS : CONDITION_OPS;
        if (ops !== shownOps) {
          const keep = op.value || c.op;
          op.replaceChildren(...ops.map(([v, label]) => el("option", { value: v, text: label })));
          if (ops.some(([v]) => v === keep)) op.value = keep;
          shownOps = ops;
        }
        value.classList.toggle("hidden", ops === VISITOR_OPS || op.value === "done" || op.value === "not_done");
      };
      item.addEventListener("change", sync);
      op.addEventListener("change", sync);
      sync();
      return [
        itemPicker,
        select("when", [["today", "today"], ["yesterday", "yesterday"]], c.when || "today"),
        op, value,
      ];
    },
    // Reads "takes 8 off Shovel" when the quest it moves counts down — the
    // amount is the same either way, it's which way that quest shows it.
    effects(fx) {
      const verb = el("span", { class: "field-hint" });
      const preposition = el("span", { class: "field-hint" });
      const { input: item, node: itemPicker } = questPicker({ "data-k": "item" }, itemOptions(), fx.item);
      const syncVerb = () => {
        const down = !!QuestRules.findItem(getBoard(), item.value)?.countDown;
        verb.textContent = down ? "takes" : "adds";
        preposition.textContent = down ? "off" : "to";
      };
      item.addEventListener("change", syncVerb);
      syncVerb();
      return [
        select("on", [["tap", "Each tap"], ["complete", "On complete"]], fx.on || "tap"),
        verb,
        el("input", { type: "number", "data-k": "amount", class: "quests-num", value: fx.amount ?? 1 }),
        preposition,
        itemPicker,
      ];
    },
    hooks(h) {
      const kind = select("kind", [["event", "Log event"], ["trigger", "Fire trigger"]], h.kind || "event");
      const label = el("input", { type: "text", "data-k": "label", value: (h.kind === "trigger" ? h.trigger : h.name) || "" });
      const notes = el("input", { type: "text", "data-k": "notes", placeholder: "Notes — {n} is the count", value: h.notes || "" });
      const syncKind = () => {
        label.placeholder = kind.value === "trigger" ? "Trigger name" : "Event name (quest name if blank)";
        notes.classList.toggle("hidden", kind.value === "trigger");
      };
      kind.addEventListener("change", syncKind);
      syncKind();
      return [select("on", [["complete", "On complete"], ["tap", "Each tap"]], h.on || "complete"), kind, label, notes];
    },
  };
  // A batch quest's rows are written exactly like "Only when" rows.
  rowBuilders.auto = rowBuilders.conditions;

  function addRow(kind, data) {
    const row = el("div", { class: "quests-row" }, rowBuilders[kind](data));
    row.appendChild(el("button", { type: "button", class: "quests-row-remove", "data-remove-row": "", "aria-label": "Remove", text: "×" }));
    form.querySelector(`[data-rows="${kind}"]`).appendChild(row);
  }

  function readRows(kind) {
    return Array.from(form.querySelectorAll(`[data-rows="${kind}"] .quests-row`)).map(row => {
      const v = k => row.querySelector(`[data-k="${k}"]`)?.value ?? "";
      if (kind === "conditions" || kind === "auto") {
        const [item, option] = v("item").split(OPTION_SEP);
        if (option) return { item, option, when: v("when"), op: v("op") };
        return { item, when: v("when"), op: v("op"), value: Number(v("value")) || 0 };
      }
      if (kind === "effects") return { on: v("on"), kind: "add", item: v("item"), amount: Number(v("amount")) || 0 };
      const hook = { on: v("on"), kind: v("kind") };
      if (hook.kind === "trigger") hook.trigger = v("label").trim();
      else { hook.name = v("label").trim(); hook.notes = v("notes").trim(); }
      return hook;
    }).filter(r => {
      if (kind === "hooks") return r.kind === "event" || r.trigger;
      return r.item && (kind !== "effects" || r.amount);
    });
  }

  // ---- open / read
  function open(item, { isNew: fresh = false } = {}) {
    editing = item;
    isNew = fresh;
    const board = getBoard();
    title.textContent = fresh ? "Add Quest" : "Edit Quest";
    deleteBtn.classList.toggle("hidden", fresh);
    const date = QuestRules.gameDate(new Date(), QuestRules.resetHourOf(board));
    resetBtn.classList.toggle("hidden", fresh || !QuestRules.countOf(board, item, date));

    const t = item.target || { mode: "fixed", value: 1 };
    const s = item.schedule || {};
    iconStack.__setIconValue(item.icon || "", { silent: true });
    field("name").value = item.name || "";
    field("target_value").value = t.mode === "fixed" ? (t.value || 1) : 1;
    field("target_when").value = t.when || "yesterday";
    field("target_scale").value = t.mode === "ref" && t.scale != null && t.scale !== 1 ? t.scale : "";
    field("section").value = item.section || "";
    field("auto_match").value = t.mode === "auto" ? (t.match || "all") : "all";
    field("auto_n").value = t.mode === "auto" && t.n ? t.n : 2;
    const target = QuestRules.resolveTarget(board, item, date);
    shownCount = fresh ? "" : String(QuestRules.shownCount(item, QuestRules.countOf(board, item, date), target));
    field("count_now").value = shownCount;
    field("step").value = item.step && item.step !== 1 ? item.step : "";
    ["startDate", "endDate", "from", "to"].forEach(k => { field(k).value = s[k] || ""; });
    setPills("target_mode", t.mode || "fixed");
    setPills("direction", item.countDown ? "down" : "up");
    setPills("reset", item.reset || "daily");
    setPills("hidden", item.hidden ? "hidden" : "shown");
    setPills("locked", item.locked ? "locked" : "tap");
    setChips("days", s.days || []);
    setChips("months", s.months || []);

    const { node: targetPicker } = questPicker({ "data-field": "target_item" }, itemOptions(), t.item);
    modal.querySelector("[data-target-picker]").replaceChildren(targetPicker);

    const sections = QuestRules.sectionNames(board);
    modal.querySelector("[data-section-list]").replaceChildren(...sections.map(n => el("option", { value: n })));

    ["conditions", "effects", "hooks"].forEach(kind => {
      form.querySelector(`[data-rows="${kind}"]`).replaceChildren();
      (item[kind] || []).forEach(row => addRow(kind, row));
    });
    form.querySelector('[data-rows="auto"]').replaceChildren();
    if (t.mode === "auto") (t.conditions || []).forEach(row => addRow("auto", row));
    syncShowFor();

    advanced.open = !!(
      item.hidden || item.locked || item.section || (item.step > 1) || s.days?.length || s.months?.length ||
      s.startDate || s.endDate || s.from || s.to ||
      item.conditions?.length || item.effects?.length || item.hooks?.length
    );
    modal.classList.remove("hidden");
    if (fresh) field("name").focus();
  }

  function close() {
    modal.classList.add("hidden");
    editing = null;
  }

  function read() {
    const mode = getPills("target_mode") || "fixed";
    const target = { mode };
    if (mode === "fixed") target.value = Math.max(1, parseInt(field("target_value").value, 10) || 1);
    if (mode === "ref") {
      target.item = field("target_item").value;
      target.when = field("target_when").value;
      const scale = parseFloat(field("target_scale").value);
      if (Number.isFinite(scale)) target.scale = scale;
    }
    if (mode === "auto") {
      target.match = field("auto_match").value || "all";
      if (target.match === "atLeast") target.n = Math.max(1, parseInt(field("auto_n").value, 10) || 1);
      target.conditions = readRows("auto");
    }
    return {
      ...editing,
      countDown: mode === "fixed" && getPills("direction") === "down",
      hidden:    getPills("hidden") === "hidden",
      locked:    getPills("target_mode") !== "auto" && getPills("locked") === "locked",
      icon:     iconStack.__iconValue().trim(),
      name:     field("name").value.trim(),
      section:  field("section").value.trim(),
      step:     Math.max(1, parseInt(field("step").value, 10) || 1),
      reset:    getPills("reset") || "daily",
      target,
      schedule: {
        days:      getChips("days"),
        months:    getChips("months"),
        startDate: field("startDate").value,
        endDate:   field("endDate").value,
        from:      field("from").value,
        to:        field("to").value,
      },
      conditions: readRows("conditions"),
      effects:    readRows("effects"),
      hooks:      readRows("hooks"),
    };
  }

  form.addEventListener("submit", e => {
    e.preventDefault();
    const item = read();
    if (!item.name) { field("name").focus(); return; }
    if (item.target.mode === "ref" && !item.target.item) item.target = { mode: "fixed", value: 1 };
    const typed = field("count_now").value.trim();
    const setTo = item.target.mode !== "auto" && typed !== "" && typed !== shownCount;
    onSave(item, { isNew });
    if (setTo) onSetCount(item, parseInt(typed, 10), { isNew });
    close();
  });

  deleteBtn.addEventListener("click", () => {
    if (!editing || !window.confirm(`Delete "${editing.name || "this quest"}"?`)) return;
    onDelete(editing);
    close();
  });

  resetBtn.addEventListener("click", () => {
    if (!editing) return;
    onReset(editing);
    close();
  });

  modal.addEventListener("click", e => {
    if (e.target === modal || e.target.closest('[data-action="cancel"]')) close();
  });

  return { open, close };
}
