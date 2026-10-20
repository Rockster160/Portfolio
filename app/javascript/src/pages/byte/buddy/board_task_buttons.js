// Task buttons in a board's settings: a circle on the board that runs a Jil
// task (the Whisper fed/quiet/nap/gone controls). A button is mostly the task
// it's attached to; its label, icon and colour are how it looks until the
// task's own tile says otherwise (see chore_board.js#followTiles).
//
// The list is kept in place - a row added, changed or removed on its own - and
// every save hands the board the circle to put in or take out, so neither the
// list nor the pad is emptied and redrawn.

const LIST_URL = "/byte/board/task_buttons";
const ITEM_URL = (id) => `/byte/board/task_buttons/${id}`;
const DEFAULT_COLOR = "#94A3B8";

// The picker: every task this person can run, searched by name and by the
// tile it answers on, every word having to match.
function initTaskPicker(dialog) {
  if (!dialog) return { open: async () => null };

  const searchEl = dialog.querySelector("[data-btp-search]");
  const listEl = dialog.querySelector("[data-btp-list]");
  const emptyEl = dialog.querySelector("[data-btp-empty]");
  let tasks = [];
  let settle = null;

  function finish(task) {
    const done = settle;
    settle = null;
    if (dialog.open) dialog.close();
    done?.(task);
  }

  function render() {
    const words = (searchEl?.value || "").toLowerCase().split(/\s+/).filter(Boolean);
    const rows = tasks
      .filter((task) => {
        const hay = `${task.name} ${task.monitor || ""}`.toLowerCase();
        return words.every((w) => hay.includes(w));
      })
      .map((task) => {
        const row = document.createElement("button");
        row.type = "button";
        row.className = "byte-board-task-option";
        const name = document.createElement("span");
        name.textContent = task.name;
        row.appendChild(name);
        if (task.monitor) {
          const tile = document.createElement("span");
          tile.className = "byte-board-task-option-tile";
          tile.textContent = "live";
          tile.title = `Answers on ${task.monitor}, so the button can show what it says`;
          row.appendChild(tile);
        }
        row.addEventListener("click", () => finish(task));
        return row;
      });
    listEl?.replaceChildren(...rows);
    if (emptyEl) emptyEl.hidden = rows.length > 0;
  }

  searchEl?.addEventListener("input", render);
  dialog.querySelector("[data-btp-cancel]")?.addEventListener("click", () => finish(null));
  dialog.addEventListener("close", () => finish(null));
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog) finish(null);
  });

  return {
    open(options) {
      tasks = options || [];
      if (searchEl) searchEl.value = "";
      render();
      return new Promise((resolve) => {
        settle = resolve;
        dialog.showModal();
        searchEl?.focus();
      });
    },
  };
}

export function initBoardTaskButtons({
  root, apiCall, tagsFn, conversationIdFn, iconFor, onSaved, onRemoved, flashSaved,
}) {
  const sectionEl = root.querySelector("[data-board-tasks-section]");
  const listEl = root.querySelector("[data-board-tasks-list]");
  const dialogEl = root.querySelector("[data-tb-dialog]");
  const formEl = root.querySelector("[data-tb-form]");
  if (!sectionEl || !listEl || !dialogEl || !formEl) return { refresh: () => {}, reset: () => {} };

  const field = (name) => formEl.querySelector(`[data-tb-${name}]`);
  const titleEl = field("title");
  const pickEl = field("task-pick");
  const hintEl = field("hint");
  const labelEl = field("label");
  const iconEl = field("icon");
  const colorEl = field("color");
  const tagsEl = field("tags");
  const idEl = field("id");
  const taskEl = field("task");
  const saveEl = field("save");
  const errorEl = field("error");
  const picker = initTaskPicker(root.querySelector("[data-board-task-picker]"));

  let tasks = [];
  let dirty = false;

  const tags = () => tagsFn() || [];
  const markDirty = () => {
    dirty = true;
    dialogEl.dataset.dirty = "true";
  };

  function showError(text) {
    if (!errorEl) return;
    errorEl.hidden = !text;
    errorEl.textContent = text || "";
  }

  // What the Runs button says, and what a blank label falls back to.
  function showTask(task) {
    if (taskEl) taskEl.value = task ? String(task.id) : "";
    if (pickEl) pickEl.textContent = task ? task.name : "Pick a task…";
    if (labelEl) labelEl.placeholder = task ? task.name : "The task's name";
    if (hintEl) {
      hintEl.hidden = !task?.monitor;
      hintEl.textContent = task?.monitor
        ? "This task answers on a live tile, so the button shows the label, icon and colour it sends."
        : "";
    }
  }

  function reset() {
    if (dialogEl.open) dialogEl.close();
    dirty = false;
    dialogEl.dataset.dirty = "false";
    if (titleEl) titleEl.textContent = "New task button";
    if (idEl) idEl.value = "";
    if (labelEl) labelEl.value = "";
    if (iconEl) iconEl.value = "";
    if (colorEl) colorEl.value = DEFAULT_COLOR;
    if (tagsEl) tagsEl.value = tags().filter((t) => t.toLowerCase() !== "all").join(", ");
    if (saveEl) saveEl.textContent = "Add button";
    showTask(null);
    showError("");
  }

  function edit(button) {
    reset();
    if (titleEl) titleEl.textContent = "Edit task button";
    if (idEl) idEl.value = String(button.id);
    if (labelEl) labelEl.value = button.label || "";
    if (iconEl) iconEl.value = button.icon || "";
    if (colorEl) colorEl.value = button.color || DEFAULT_COLOR;
    if (tagsEl) tagsEl.value = (button.tags || []).join(", ");
    if (saveEl) saveEl.textContent = "Save";
    showTask(tasks.find((t) => t.id === button.task_id) || { id: button.task_id, name: button.task_name, monitor: button.monitor });
    dialogEl.showModal();
  }

  function buildRow(button) {
    const row = document.createElement("div");
    row.className = "byte-board-button-row";
    row.dataset.tbRow = String(button.id);

    const open = document.createElement("button");
    open.type = "button";
    open.className = "byte-board-button-edit";
    const swatch = document.createElement("span");
    swatch.className = "byte-board-button-swatch";
    const label = document.createElement("span");
    label.className = "byte-board-button-label";
    const runs = document.createElement("span");
    runs.className = "byte-board-button-who";
    open.append(swatch, label, runs);
    open.addEventListener("click", () => edit(row._button));

    const del = document.createElement("button");
    del.type = "button";
    del.className = "byte-board-button-del";
    del.textContent = "×";
    del.addEventListener("click", () => remove(row._button));

    row.append(open, del);
    return row;
  }

  function fillRow(row, button) {
    row._button = button;
    const swatch = row.querySelector(".byte-board-button-swatch");
    swatch.replaceChildren();
    swatch.style.background = button.icon ? "" : button.color || "";
    if (button.icon) swatch.appendChild(iconFor({ icon: button.icon, short_name: button.label }));
    row.querySelector(".byte-board-button-label").textContent = button.label;
    row.querySelector(".byte-board-button-who").textContent = `Runs ${button.task_name || "a task you can't see any more"}`;
    row.querySelector(".byte-board-button-del").setAttribute("aria-label", `Delete ${button.label}`);
  }

  function paintEmpty() {
    let none = listEl.querySelector("[data-tb-none]");
    const empty = !listEl.querySelector("[data-tb-row]");
    if (empty && !none) {
      none = document.createElement("p");
      none.className = "byte-board-tag-empty";
      none.dataset.tbNone = "";
      none.textContent = "No task buttons on this board yet.";
      listEl.appendChild(none);
    }
    if (!empty) none?.remove();
  }

  // One row in place: changed, added at the end, or (when it no longer
  // belongs to this board's groups) taken out.
  function upsertRow(button, belongs = true) {
    let row = listEl.querySelector(`[data-tb-row="${button.id}"]`);
    if (!belongs) {
      row?.remove();
    } else {
      if (!row) {
        row = buildRow(button);
        listEl.appendChild(row);
      }
      fillRow(row, button);
    }
    paintEmpty();
  }

  // The list as the server has it, matched to the rows already there.
  async function refresh() {
    const named = tags().filter((t) => t.toLowerCase() !== "all");
    sectionEl.hidden = !named.length;
    if (!named.length) return;

    try {
      const data = await apiCall(`${LIST_URL}?tags=${encodeURIComponent(named.join(","))}`, "GET");
      tasks = Array.isArray(data?.tasks) ? data.tasks : [];
      const buttons = Array.isArray(data?.buttons) ? data.buttons : [];
      const keepIds = new Set(buttons.map((b) => String(b.id)));
      listEl.querySelectorAll("[data-tb-row]").forEach((row) => {
        if (!keepIds.has(row.dataset.tbRow)) row.remove();
      });
      buttons.forEach((button) => upsertRow(button));
      paintEmpty();
    } catch (e) {
      // The list stays as it was; the board itself still works.
    }
  }

  // On this board when it shares one of the groups the board watches.
  function belongsHere(button) {
    const mine = tags().map((t) => t.toLowerCase());
    return (button.tags || []).some((t) => mine.includes(String(t).toLowerCase()));
  }

  async function submit(e) {
    e.preventDefault();
    if (!taskEl?.value) return showError("Pick the task it runs.");

    const id = idEl?.value;
    const payload = {
      conversation_id: conversationIdFn?.(),
      button: {
        task_id: taskEl.value,
        label: labelEl?.value.trim() || "",
        icon: iconEl?.value.trim() || "",
        color: colorEl?.value || "",
        tags_csv: tagsEl?.value || "",
      },
    };
    try {
      const data = await apiCall(id ? ITEM_URL(id) : LIST_URL, id ? "PATCH" : "POST", payload);
      const button = data?.button;
      if (!button) throw new Error("no_button");
      const belongs = belongsHere(button);
      upsertRow(button, belongs);
      onSaved?.(data.item, belongs);
      reset();
      flashSaved?.();
    } catch (err) {
      showError(err.body?.errors?.join(", ") || "Couldn't save that button.");
    }
  }

  async function remove(button) {
    if (!button) return;
    try {
      await apiCall(`${ITEM_URL(button.id)}?conversation_id=${encodeURIComponent(conversationIdFn?.() ?? "")}`, "DELETE");
      upsertRow(button, false);
      onRemoved?.(button.id);
      if (idEl?.value === String(button.id)) reset();
      flashSaved?.();
    } catch (e) {
      // Still there to try again.
    }
  }

  root.querySelector("[data-tb-new]")?.addEventListener("click", () => {
    reset();
    dialogEl.showModal();
  });
  field("cancel")?.addEventListener("click", reset);
  pickEl?.addEventListener("click", async () => {
    if (!tasks.length) await refresh();
    const task = await picker.open(tasks);
    if (!task) return;
    showTask(task);
    markDirty();
  });
  formEl.addEventListener("submit", submit);
  formEl.addEventListener("input", markDirty);
  dialogEl.addEventListener("close", () => {
    if (dirty || idEl?.value) reset();
  });

  return { refresh, reset };
}
