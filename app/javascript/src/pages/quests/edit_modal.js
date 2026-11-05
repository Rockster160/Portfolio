// The full quest editor: name and count up top, everything else — section,
// step, schedule, conditions, effects on other quests, hooks — folded under
// one disclosure that opens by itself when the quest already uses any of it.

import QuestRules from "./rules";
import { bindIconStack } from "../../icon_stack";

const CONDITION_OPS = [
  ["done", "is done"], ["not_done", "isn't done"],
  [">", "more than"], [">=", "at least"], ["=", "exactly"],
  ["<=", "at most"], ["<", "fewer than"], ["!=", "not"],
];

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

export function setupEditModal({ getBoard, onSave, onDelete, onReset }) {
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

  const field = name => form.querySelector(`[data-field="${name}"]`);

  function itemOptions() {
    const board = getBoard();
    const date = QuestRules.gameDate(new Date(), QuestRules.resetHourOf(board));
    return board.items.filter(i => i.id !== editing?.id).map(i => {
      const label = QuestRules.displayName(i, QuestRules.resolveTarget(board, i, date)) || "(unnamed)";
      return [i.id, `${i.icon ? `${i.icon} ` : ""}${label}`];
    });
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

  // ---- repeating rows
  const rowBuilders = {
    conditions(c) {
      const value = el("input", { type: "number", "data-k": "value", class: "quests-num", value: c.value ?? 0 });
      const op = select("op", CONDITION_OPS, c.op || "done");
      const syncValue = () => value.classList.toggle("hidden", op.value === "done" || op.value === "not_done");
      op.addEventListener("change", syncValue);
      syncValue();
      return [
        select("item", itemOptions(), c.item),
        select("when", [["today", "today"], ["yesterday", "yesterday"]], c.when || "today"),
        op, value,
      ];
    },
    effects(fx) {
      return [
        select("on", [["tap", "Each tap"], ["complete", "On complete"]], fx.on || "tap"),
        el("span", { class: "field-hint", text: "adds" }),
        el("input", { type: "number", "data-k": "amount", class: "quests-num", value: fx.amount ?? 1 }),
        el("span", { class: "field-hint", text: "to" }),
        select("item", itemOptions(), fx.item),
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

  function addRow(kind, data) {
    const row = el("div", { class: "quests-row" }, rowBuilders[kind](data));
    row.appendChild(el("button", { type: "button", class: "quests-row-remove", "data-remove-row": "", "aria-label": "Remove", text: "×" }));
    form.querySelector(`[data-rows="${kind}"]`).appendChild(row);
  }

  function readRows(kind) {
    return Array.from(form.querySelectorAll(`[data-rows="${kind}"] .quests-row`)).map(row => {
      const v = k => row.querySelector(`[data-k="${k}"]`)?.value ?? "";
      if (kind === "conditions") return { item: v("item"), when: v("when"), op: v("op"), value: Number(v("value")) || 0 };
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
    field("step").value = item.step && item.step !== 1 ? item.step : "";
    ["startDate", "endDate", "from", "to"].forEach(k => { field(k).value = s[k] || ""; });
    setPills("target_mode", t.mode || "fixed");
    setPills("reset", item.reset || "daily");
    setChips("days", s.days || []);
    setChips("months", s.months || []);

    const targetSelect = field("target_item");
    targetSelect.replaceChildren(...itemOptions().map(([v, label]) => el("option", { value: v, text: label })));
    if (t.item) targetSelect.value = t.item;

    const sections = [...new Set(board.items.map(i => i.section).filter(Boolean))];
    modal.querySelector("[data-section-list]").replaceChildren(...sections.map(n => el("option", { value: n })));

    ["conditions", "effects", "hooks"].forEach(kind => {
      form.querySelector(`[data-rows="${kind}"]`).replaceChildren();
      (item[kind] || []).forEach(row => addRow(kind, row));
    });

    advanced.open = !!(
      item.section || (item.step > 1) || s.days?.length || s.months?.length ||
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
    return {
      ...editing,
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
    onSave(item, { isNew });
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
