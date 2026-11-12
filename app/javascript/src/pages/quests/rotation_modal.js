// The rotation form: a name and icon for the whole thing, then one row per
// option — its own icon, a name, and whether it's a daily pick (on any day or
// a fixed one) or an extra that can turn up alongside.

import QuestRotation from "./rotation";
import { bindIconStack } from "../../icon_stack";
import { loadIconPool } from "../../icon_picker";

const DAYS = [["", "Any day"], ["1", "Mon"], ["2", "Tue"], ["3", "Wed"], ["4", "Thu"], ["5", "Fri"], ["6", "Sat"], ["0", "Sun"]];

function el(tag, attrs = {}) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => {
    if (k === "text") node.textContent = v;
    else node.setAttribute(k, v);
  });
  return node;
}

function select(key, options, value) {
  const node = el("select", { "data-k": key });
  options.forEach(([v, label]) => node.appendChild(el("option", { value: v, text: label })));
  node.value = String(value ?? "");
  return node;
}

export function setupRotationModal({ getBoard, onSave, onDelete }) {
  const modal = document.querySelector("[data-rotation-modal]");
  const form = modal.querySelector("[data-rotation-form]");
  const title = modal.querySelector("[data-rotation-title]");
  const nameInput = form.querySelector('[data-rotation-field="name"]');
  const sectionInput = form.querySelector('[data-rotation-field="section"]');
  const rowsEl = form.querySelector("[data-rotation-options]");
  const deleteBtn = form.querySelector("[data-rotation-delete]");
  const iconStack = form.querySelector("[data-rotation-icon] [data-icon-stack]");
  const rowTemplate = modal.querySelector('[data-template="rotation-option"]');
  bindIconStack(iconStack);
  let editing = null;
  let isNew = false;

  function addRow(option) {
    const row = rowTemplate.content.firstElementChild.cloneNode(true);
    row.dataset.optionId = option.id;
    const stack = row.querySelector("[data-icon-stack]");
    const bound = bindIconStack(stack);
    stack.__setIconValue(option.icon || "", { silent: true });
    loadIconPool().then(() => bound?.render?.());

    const name = row.querySelector('[data-k="name"]');
    name.value = option.name || "";
    const slot = select("slot", [["main", "Daily pick"], ["extra", "Extra"]], option.slot || "main");
    const day = select("day", DAYS, QuestRotation.fixedDay(option) ?? "");
    const syncDay = () => day.classList.toggle("hidden", slot.value === "extra");
    slot.addEventListener("change", syncDay);
    syncDay();
    row.querySelector("[data-option-settings]").append(slot, day);
    rowsEl.appendChild(row);
    return row;
  }

  function readOptions() {
    return Array.from(rowsEl.querySelectorAll("[data-option-id]")).map(row => {
      const v = k => row.querySelector(`[data-k="${k}"]`)?.value ?? "";
      const slot = v("slot") === "extra" ? "extra" : "main";
      const day = parseInt(v("day"), 10);
      return {
        id:   row.dataset.optionId,
        name: v("name").trim(),
        icon: row.querySelector("[data-icon-stack]").__iconValue().trim(),
        slot,
        day:  slot === "main" && day >= 0 ? day : null,
      };
    }).filter(o => o.name || o.icon);
  }

  function open(item, { isNew: fresh = false } = {}) {
    editing = item;
    isNew = fresh;
    title.textContent = fresh ? "Add Rotation" : "Edit Rotation";
    deleteBtn.classList.toggle("hidden", fresh);
    nameInput.value = item.name || "";
    sectionInput.value = item.section || "";
    iconStack.__setIconValue(item.icon || "", { silent: true });
    rowsEl.replaceChildren();
    (item.options || []).forEach(addRow);
    if (!item.options?.length) addRow(QuestRotation.newOption());
    const sections = [...new Set(getBoard().items.map(i => i.section).filter(Boolean))];
    modal.querySelector("[data-rotation-sections]").replaceChildren(...sections.map(n => el("option", { value: n })));
    modal.classList.remove("hidden");
    if (fresh) nameInput.focus();
  }

  function close() {
    modal.classList.add("hidden");
    editing = null;
  }

  form.addEventListener("click", e => {
    if (e.target.closest("[data-rotation-add]")) {
      addRow(QuestRotation.newOption()).querySelector('[data-k="name"]').focus();
      return;
    }
    const remove = e.target.closest("[data-remove-option]");
    if (remove) remove.closest("[data-option-id]")?.remove();
  });

  form.addEventListener("submit", e => {
    e.preventDefault();
    const name = nameInput.value.trim();
    if (!name) { nameInput.focus(); return; }
    onSave({
      ...editing,
      name,
      icon:    iconStack.__iconValue().trim(),
      section: sectionInput.value.trim(),
      options: readOptions(),
    }, { isNew });
    close();
  });

  deleteBtn.addEventListener("click", () => {
    if (!editing || !window.confirm(`Delete "${editing.name || "this rotation"}" and everything picked on it?`)) return;
    onDelete(editing);
    close();
  });

  modal.addEventListener("click", e => {
    if (e.target === modal || e.target.closest('[data-action="cancel"]')) close();
  });

  return { open, close };
}
