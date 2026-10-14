// The saved-routines manager, opened from the Byte drawer.
//
// A routine's STEPS are tool calls with validated arguments, which is a bad
// thing to hand-edit in a TEXT BOX - and that was the whole objection, so this
// isn't one. The builder draws its fields from the tool registry, which already
// declares every argument, its type and whether it's required, so it can only
// offer arguments that exist; and the server runs the same `sanitize` a routine
// saved in conversation goes through, including each tool's own `confirm`. A
// step naming a chore that isn't there is refused with the tool's own sentence
// rather than saved broken.
//
// The rest is what conversation is bad at: seeing everything at once, fixing a
// name, muting one, throwing one away, dropping a step, dragging them into a
// different order and changing how many times one runs.
//
// Hydrated when the drawer opens rather than at boot — most sessions never
// open it, and the list is only interesting once it's on screen.
//
// Pinning is the one thing here that isn't housekeeping. Every enabled routine
// is already on the Quick grid and the wall tablet; starring one moves it to
// the front of both, and their order there is the order they drag them into.

import Sortable from "../../../../jil/Sortable.min.js";
import { escapeHtml, escapeAttr, fieldFor, readPayload, stepPhrase, durationRead } from "./routine_step.js";

async function apiCall(url, method, body) {
  const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
  const options = {
    method,
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-CSRF-Token": csrf },
  };
  if (body != null) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const res = await fetch(url, options);
  if (!res.ok) {
    // Carry the server's own sentence up. A refused step is a tool saying why
    // it can't run - "there's no chore called Bins" - and that is strictly
    // better than anything this file could write in its place.
    const said = await res.json().catch(() => null);
    const error = new Error(`http_${res.status}`);
    error.detail = Array.isArray(said?.errors) ? said.errors.join("; ") : (said?.error || null);
    throw error;
  }
  if (res.status === 204) return null;
  return res.json();
}

export function initBuddyRoutines({
  panel, list, empty, indexUrl, onCount,
  addBtn, picker, pickerList, pickerEmpty, pickerSearch,
  newBtn, builder, builderForm, builderTitle, builderAbout, builderName, builderDesc,
  builderMade, builderSteps, builderNone, builderSave, builderCancel, builderError,
  toolPick, toolSearch, toolList, toolNone, toolArgs,
}) {
  if (!panel || !list) return null;

  let routines = [];
  let loading  = false;
  let sortable = null;

  // Pinned first, in grid order, so the drawer reads the way the Quick grid
  // looks — dragging one here is only meaningful if you can see the order
  // you're dragging it into.
  function pinned() {
    return routines
      .filter((r) => r.position != null)
      .sort((a, b) => a.position - b.position);
  }

  function sorted() {
    return pinned().concat(routines.filter((r) => r.position == null));
  }

  function pinnedIds() {
    return pinned().map((r) => r.id);
  }

  function render() {
    // The panel is a dialog you deliberately opened, so an empty one owes you
    // an explanation rather than hiding itself the way the inline drawer
    // section used to.
    if (empty) empty.hidden = routines.length > 0;
    onCount?.(routines.length);
    list.innerHTML = sorted().map((r) => {
      const steps  = stepRowsFor(r);
      const off    = r.enabled ? "" : " byte-routine-off";
      const isPin  = r.position != null;
      // Only pinned rows are draggable: the order being dragged into is the
      // Quick grid's, and an unpinned routine isn't on it.
      const drag   = isPin ? " byte-routine-pinned" : "";
      // The grip is separate from the star on purpose: the star is a tap and
      // the grip is a drag, and one element answering to both means every
      // slightly-moved tap is ambiguous.
      const handle = `<span class="byte-routine-grip" data-routine-grip aria-hidden="true">⠿</span>`;
      const grip   = isPin ? handle : "";
      // "Front" rather than "add/remove": every enabled routine is already on
      // the Quick grid and the wall, and starring is what moves it up.
      const pinTip = isPin ? "Unpin from the front" : "Pin to the front";
      return `
        <li class="byte-routine${off}${drag}" data-routine-id="${r.id}">
          <div class="byte-routine-head">
            ${grip}
            <button type="button" class="byte-routine-pin" data-routine-pin aria-pressed="${isPin}" title="${pinTip}" aria-label="${pinTip}">${isPin ? "★" : "☆"}</button>
            <button type="button" class="byte-routine-name" data-routine-rename title="Rename">${escapeHtml(r.name)}</button>
            <button type="button" class="byte-routine-group${(r.tags && r.tags.length) ? " byte-routine-group-set" : ""}" data-routine-group title="Board groups — which chore boards this routine appears on">${(r.tags && r.tags.length) ? escapeHtml(r.tags.join(", ")) : "group"}</button>
            <button type="button" class="byte-routine-toggle" data-routine-toggle aria-label="${r.enabled ? "Turn off" : "Turn on"}">${r.enabled ? "on" : "off"}</button>
            <button type="button" class="byte-routine-remove" data-routine-remove aria-label="Delete">×</button>
          </div>
          ${r.description ? `<p class="byte-routine-desc">${escapeHtml(r.description)}</p>` : ""}
          <ol class="byte-routine-steps" data-routine-steps>${steps}</ol>
          <button type="button" class="byte-routine-addstep" data-routine-add-step>＋ step</button>
        </li>
      `;
    }).join("");
    bindSortable();
    bindStepSortables();
  }

  // The count has its own control, so the "×3" step_phrase tacks on would be
  // the same number said twice.
  function phraseOf(step) {
    return step.countable ? step.phrase.replace(/\s*×\d+\s*$/, "") : step.phrase;
  }

  function stepRowsFor(routine) {
    const rows = routine.step_rows || [];
    // Removing the last step would leave a routine that can't run, and the
    // server refuses it - so don't offer the button rather than explaining the
    // refusal afterwards. Deleting the whole routine is right there.
    const removable = rows.length > 1;

    return rows.map((s) => `
      <li class="byte-step" data-step-index="${s.index}" data-step-count="${s.count}">
        <span class="byte-step-grip" data-step-grip aria-hidden="true">⠿</span>
        <span class="byte-step-phrase">${escapeHtml(phraseOf(s))}</span>
        ${s.countable ? `
          <span class="byte-step-count">
            <button type="button" class="byte-step-step" data-step-less aria-label="One fewer">−</button>
            <span class="byte-step-times">×${s.count}</span>
            <button type="button" class="byte-step-step" data-step-more aria-label="One more">+</button>
          </span>
        ` : ""}
        ${removable ? `<button type="button" class="byte-step-remove" data-step-remove aria-label="Remove step">×</button>` : ""}
      </li>
    `).join("");
  }

  // Rebuilt after every render because render() replaces the whole list.
  function bindSortable() {
    sortable?.destroy();
    sortable = Sortable.create(list, {
      animation:     150,
      draggable:     ".byte-routine-pinned",
      handle:        ".byte-routine-grip",
      ghostClass:    "byte-routine-ghost",
      // Matches the timers board: the native HTML5 drag is unreliable inside a
      // scrolling drawer on iOS.
      forceFallback:     true,
      fallbackOnBody:    true,
      fallbackTolerance: 0,
      onEnd: () => {
        const ids = Array.from(list.querySelectorAll(".byte-routine-pinned"))
          .map((el) => Number(el.dataset.routineId))
          .filter(Boolean);
        reorder(ids);
      },
    });
  }

  // One Sortable per routine, because a step belongs to its own routine and
  // dragging one across into another would be meaningless.
  function bindStepSortables() {
    list.querySelectorAll("[data-routine-steps]").forEach((ol) => {
      Sortable.create(ol, {
        animation:         150,
        handle:            ".byte-step-grip",
        ghostClass:        "byte-step-ghost",
        forceFallback:     true,
        fallbackOnBody:    true,
        fallbackTolerance: 0,
        onEnd: (evt) => {
          const routine = routineFor(evt.to);
          if (routine) saveSteps(routine, evt.to);
        },
      });
    });
  }

  // The whole step list every time, same as the grid reorder: the order is one
  // fact, and a per-step request would leave it half-applied if one failed.
  //
  // Read off the DOM rather than from state, because after a drag the DOM IS
  // the order - nothing else knows about it yet.
  async function saveSteps(routine, ol) {
    const steps = Array.from(ol.querySelectorAll("[data-step-index]")).map((li) => ({
      index: Number(li.dataset.stepIndex),
      count: Number(li.dataset.stepCount) || 1,
    }));

    try {
      const updated = await apiCall(`${indexUrl}/${routine.id}/steps`, "PATCH", { steps });
      if (!updated) return;
      const i = routines.findIndex((r) => r.id === routine.id);
      if (i >= 0) routines[i] = updated;
      render();
    } catch (e) {
      // Put the steps back the way the server still has them, rather than
      // leaving a drag on screen that didn't save.
      render();
    }
  }

  // One request for the whole grid. Positions are rewritten from the list sent,
  // and anything left out is unpinned — so this is pin, unpin and reorder.
  async function reorder(ids) {
    try {
      const data = await apiCall(`${indexUrl}/reorder`, "POST", { ids });
      if (data && Array.isArray(data.routines)) {
        routines = data.routines;
        render();
      }
    } catch (e) {
      // Put the rows back where the server still thinks they are, rather than
      // leaving the drag showing an order that didn't save.
      render();
    }
  }

  async function refresh() {
    if (loading) return;
    loading = true;
    try {
      const data = await apiCall(indexUrl, "GET");
      if (data && Array.isArray(data.routines)) {
        routines = data.routines;
        render();
      }
    } catch (e) {
      // A drawer that can't reach the server just shows what it had. The
      // routines still run — this panel is not on the path that matters.
    } finally {
      loading = false;
    }
  }

  function routineFor(el) {
    const row = el.closest?.("[data-routine-id]");
    if (!row) return null;
    const id = Number(row.dataset.routineId);
    return routines.find((r) => r.id === id) || null;
  }

  async function patch(routine, attrs) {
    try {
      const updated = await apiCall(`${indexUrl}/${routine.id}`, "PATCH", { routine: attrs });
      if (!updated) return;
      const i = routines.findIndex((r) => r.id === routine.id);
      if (i >= 0) routines[i] = updated;
      render();
    } catch (e) {}
  }

  // ---- adding a Jil automation as a one-tap button ----
  //
  // The server only offers the ones firable by name alone. A task with data
  // filters on its listener needs a payload built, and there's nowhere on a
  // button to say what that payload is — so those stay conversational rather
  // than becoming a button that looks fine and never fires.

  let jilActions = [];

  // Name, description and the raw scope all match, because which one you'd
  // reach for depends on the automation: "Scene: Chill" is findable by name,
  // an ESP button is only findable by what its description says it does, and
  // someone who wrote the listener will type the scope.
  function matching(term) {
    const q = term.trim().toLowerCase();
    if (!q) return jilActions;
    return jilActions.filter((a) =>
      `${a.name} ${a.description || ""} ${a.scope || ""}`.toLowerCase().includes(q));
  }

  function paintPicker() {
    if (!pickerList) return;
    const term = pickerSearch?.value || "";
    const shown = matching(term);

    if (pickerEmpty) {
      // Two different nothings: nothing left to add at all, versus nothing
      // matching what they typed. Saying "everything already has a button"
      // to someone mid-search would read as a bug.
      pickerEmpty.hidden = shown.length > 0;
      pickerEmpty.textContent = jilActions.length === 0
        ? "Nothing left to add — every automation you can fire by name already has a button."
        : `No automation matches “${term.trim()}”.`;
    }

    pickerList.innerHTML = shown.map((a) => `
      <li class="byte-jil-action" data-jil-id="${a.id}" data-jil-name="${escapeAttr(a.name)}">
        <button type="button" class="byte-jil-add" data-jil-add>
          <span class="byte-jil-name">${escapeHtml(a.name)}</span>
          ${a.description ? `<span class="byte-jil-desc">${escapeHtml(a.description)}</span>` : ""}
          <span class="byte-jil-scope">${escapeHtml(a.scope || "")}</span>
        </button>
      </li>
    `).join("");
  }

  async function togglePicker() {
    if (!picker) return;
    if (!picker.hidden) {
      picker.hidden = true;
      return;
    }
    picker.hidden = false;
    if (pickerSearch) pickerSearch.value = "";
    try {
      const data = await apiCall(`${indexUrl}/jil_actions`, "GET");
      jilActions = Array.isArray(data?.actions) ? data.actions : [];
    } catch (e) {
      jilActions = [];
    }
    paintPicker();
    pickerSearch?.focus();
  }

  pickerSearch?.addEventListener("input", paintPicker);

  async function addJil(id, taskName) {
    // Prefilled with the automation's own name, because that's usually right,
    // and editable because a wall button wants "Preheat" where the task is
    // called "Printer - Preheat".
    const label = window.prompt("Button label", taskName);
    if (label === null) return;

    try {
      await apiCall(indexUrl, "POST", { task_id: id, name: label.trim() || taskName });
      if (picker) picker.hidden = true;
      await refresh();
    } catch (e) {
      window.alert("Couldn't add that one.");
    }
  }

  addBtn?.addEventListener("click", togglePicker);
  pickerList?.addEventListener("click", (e) => {
    const row = e.target.closest?.("[data-jil-id]");
    if (row && e.target.closest("[data-jil-add]")) addJil(Number(row.dataset.jilId), row.dataset.jilName);
  });

  // ---- building one out of the registry's own fields ----
  //
  // Its own dialog rather than a panel unfolding under the list: it is a form
  // you fill in and finish, and three bare fields stacked under the last saved
  // routine read as part of that routine.
  //
  // Two modes, one form. With no routine named it collects steps into a draft
  // and saves them as a new routine; opened from a row's "＋ step" it appends to
  // that routine as soon as the step is filled in, because there is nothing to
  // name and nothing left to save.

  let tools    = [];
  let draft    = [];
  let appendTo = null;
  let chosen   = null;

  async function loadTools() {
    if (tools.length) return;
    try {
      const data = await apiCall(`${indexUrl}/tools`, "GET");
      tools = Array.isArray(data?.tools) ? data.tools : [];
    } catch (e) {
      tools = [];
    }
  }

  function showError(message) {
    if (!builderError) return;
    builderError.textContent = message || "";
    builderError.hidden = !message;
  }

  // Name and description match, because which one you'd search by depends on
  // the tool: "complete chore" is findable by name and "put something on a
  // list" by what the line under it says.
  function matchingTools() {
    const q = (toolSearch?.value || "").trim().toLowerCase();
    if (!q) return tools;
    return tools.filter((t) => `${t.label} ${t.description || ""}`.toLowerCase().includes(q));
  }

  function paintTools() {
    if (!toolList) return;
    const shown = matchingTools();

    if (toolNone) {
      toolNone.hidden = shown.length > 0;
      toolNone.textContent = tools.length
        ? `No action matches “${(toolSearch?.value || "").trim()}”.`
        : "Couldn't load the actions.";
    }

    toolList.innerHTML = shown.map((t) => `
      <li class="byte-tool" data-tool-name="${escapeAttr(t.name)}">
        <button type="button" class="byte-tool-pick" data-tool-pick>
          <span class="byte-tool-label">${escapeHtml(t.label)}</span>
          ${t.description ? `<span class="byte-tool-desc">${escapeHtml(t.description)}</span>` : ""}
        </button>
      </li>
    `).join("");
  }

  function paintArgs() {
    if (!toolArgs) return;

    // The picker hides while an action is being filled in. Picking a second one
    // halfway through would throw away what had been typed with nothing said.
    if (toolPick) toolPick.hidden = chosen != null;

    if (!chosen) {
      toolArgs.hidden = true;
      toolArgs.innerHTML = "";
      return;
    }

    const args  = chosen.args || [];
    const shown = args.filter((a) => !a.advanced).map(fieldFor).join("");
    const rest  = args.filter((a) => a.advanced);

    // Folded rather than dropped. Everything a tool takes is still reachable -
    // the repeating work/break rhythm, the stop condition - but a form opens on
    // the one or two decisions somebody actually came to make.
    const more = rest.length
      ? `<details class="byte-arg-more">
           <summary>More options (${rest.length})</summary>
           ${rest.map(fieldFor).join("")}
         </details>`
      : "";

    toolArgs.hidden = false;
    toolArgs.innerHTML = `
      <h4 class="byte-builder-heading">${escapeHtml(chosen.label)}</h4>
      ${chosen.description ? `<p class="byte-arg-blurb">${escapeHtml(chosen.description)}</p>` : ""}
      ${shown || (more ? "" : `<p class="byte-builder-none">Nothing to fill in.</p>`)}
      ${more}
      <div class="byte-modal-actions">
        <button type="button" class="byte-modal-btn" data-arg-back>Back</button>
        <button type="button" class="byte-modal-btn byte-modal-btn-primary" data-arg-add>Add step</button>
      </div>
    `;
    paintReadbacks();
    toolArgs.querySelector(".byte-modal-input")?.focus();
  }

  // The elements the fields were drawn into, handed to readPayload so it can
  // stay free of the DOM.
  function fieldValue(arg) {
    const el = toolArgs.querySelector(`[data-arg-key="${arg.key}"]`);
    return el && { value: el.value, checked: el.checked };
  }

  // "4m30" is four and a half minutes, which is only obvious once something
  // says so - and a length nothing can read has to say that while it is still
  // being typed rather than on the way out.
  function paintReadbacks() {
    toolArgs?.querySelectorAll('[data-arg-type="duration"]').forEach((el) => {
      const line = toolArgs.querySelector(`[data-arg-read="${el.dataset.argKey}"]`);
      if (!line) return;

      const said = durationRead(el.value);
      line.textContent = said;
      line.dataset.unreadable = said.startsWith("Can't") ? "true" : "false";
    });
  }

  toolArgs?.addEventListener("input", (e) => {
    if (e.target.dataset?.argType === "duration") paintReadbacks();
  });

  function paintDraft() {
    // Nothing to draft when appending: the step lands on save, and the routine's
    // own steps are on the row behind this dialog.
    if (builderMade) builderMade.hidden = appendTo != null;
    if (builderNone) builderNone.hidden = draft.length > 0;
    if (!builderSteps) return;

    builderSteps.innerHTML = draft.map((step, i) => `
      <li class="byte-step" data-draft-index="${i}">
        <span class="byte-step-phrase">${escapeHtml(stepPhrase(step))}</span>
        <button type="button" class="byte-step-remove" data-draft-remove aria-label="Remove step">×</button>
      </li>
    `).join("");
  }

  function closeBuilder() {
    draft = [];
    appendTo = null;
    chosen = null;
    showError("");
    paintDraft();
    paintArgs();
    if (!builder) return;
    if (typeof builder.close === "function") builder.close();
    else builder.removeAttribute("open");
  }

  async function openBuilder(routine) {
    if (!builder) return;
    if (picker) picker.hidden = true;

    appendTo = routine ? routine.id : null;
    draft = [];
    chosen = null;
    showError("");

    // Appending has nothing to name and nothing to hold back: the step lands
    // the moment it's filled in, so a Save button would be a second press that
    // does nothing.
    if (builderTitle) builderTitle.textContent = routine ? `Add a step to “${routine.name}”` : "New routine";
    if (builderAbout) builderAbout.hidden = appendTo != null;
    if (builderSave) builderSave.hidden = appendTo != null;
    if (builderName) builderName.value = "";
    if (builderDesc) builderDesc.value = "";
    if (toolSearch) toolSearch.value = "";
    paintDraft();
    paintArgs();

    if (typeof builder.showModal === "function") builder.showModal();
    else builder.setAttribute("open", "");

    await loadTools();
    paintTools();
    (appendTo == null ? builderName : toolSearch)?.focus();
  }

  // In append mode this is the whole transaction: the existing steps by index,
  // plus the new one, which is the shape #steps takes anyway.
  async function appendStep(step) {
    const routine = routines.find((r) => r.id === appendTo);
    if (!routine) return closeBuilder();

    const steps = (routine.step_rows || []).map((s) => ({ index: s.index, count: s.count }));
    steps.push(step);

    try {
      const updated = await apiCall(`${indexUrl}/${routine.id}/steps`, "PATCH", { steps });
      const i = routines.findIndex((r) => r.id === routine.id);
      if (i >= 0 && updated) routines[i] = updated;
      closeBuilder();
      render();
    } catch (e) {
      showError(e.detail || "Couldn't add that step.");
    }
    return undefined;
  }

  function addStep() {
    if (!chosen) return undefined;

    const { payload, missing } = readPayload(chosen.args, fieldValue);
    if (missing.length) return showError(`Still needs ${missing.join(", ")}.`);

    const step = { tool_name: chosen.name, payload };
    showError("");
    if (appendTo != null) return appendStep(step);

    draft.push(step);
    chosen = null;
    paintDraft();
    paintArgs();
    if (toolSearch) toolSearch.value = "";
    paintTools();
    toolSearch?.focus();
    return undefined;
  }

  async function saveDraft() {
    const name = (builderName?.value || "").trim();
    if (!name) {
      showError("Give it a name first.");
      builderName?.focus();
      return;
    }
    if (!draft.length) {
      showError("Add at least one step.");
      return;
    }

    try {
      await apiCall(indexUrl, "POST", {
        name,
        description: (builderDesc?.value || "").trim(),
        steps: draft,
      });
      closeBuilder();
      await refresh();
    } catch (e) {
      showError(e.detail || "Couldn't save that one.");
    }
  }

  newBtn?.addEventListener("click", () => openBuilder(null));
  builderSave?.addEventListener("click", saveDraft);
  builderCancel?.addEventListener("click", closeBuilder);
  toolSearch?.addEventListener("input", paintTools);

  // Enter does the nearest sensible thing instead of submitting the dialog
  // closed: finish the action being filled in, or save what's there.
  builderForm?.addEventListener("submit", (e) => {
    e.preventDefault();
    if (chosen) addStep();
    else if (appendTo == null) saveDraft();
  });

  // Esc and the backdrop close a <dialog> without going through Cancel, and a
  // half-built draft left in memory would reappear the next time it opened.
  builder?.addEventListener("close", () => {
    draft = [];
    appendTo = null;
    chosen = null;
    showError("");
  });

  toolList?.addEventListener("click", (e) => {
    const row = e.target.closest?.("[data-tool-name]");
    if (!row || !e.target.closest("[data-tool-pick]")) return;
    chosen = tools.find((t) => t.name === row.dataset.toolName) || null;
    showError("");
    paintArgs();
  });

  toolArgs?.addEventListener("click", (e) => {
    if (e.target.closest("[data-arg-add]")) {
      addStep();
      return;
    }
    if (e.target.closest("[data-arg-back]")) {
      chosen = null;
      showError("");
      paintArgs();
      toolSearch?.focus();
    }
  });

  builderSteps?.addEventListener("click", (e) => {
    const row = e.target.closest?.("[data-draft-index]");
    if (!row || !e.target.closest("[data-draft-remove]")) return;
    draft.splice(Number(row.dataset.draftIndex), 1);
    paintDraft();
  });

  list.addEventListener("click", async (e) => {
    const routine = routineFor(e.target);
    if (!routine) return;

    if (e.target.closest("[data-routine-add-step]")) {
      openBuilder(routine);
      return;
    }

    const step = e.target.closest?.("[data-step-index]");
    if (step) {
      const ol = step.closest("[data-routine-steps]");
      if (e.target.closest("[data-step-remove]")) {
        step.remove();
        saveSteps(routine, ol);
        return;
      }
      const less = e.target.closest("[data-step-less]");
      const more = e.target.closest("[data-step-more]");
      if (less || more) {
        const now = Number(step.dataset.stepCount) || 1;
        step.dataset.stepCount = Math.min(20, Math.max(1, now + (more ? 1 : -1)));
        saveSteps(routine, ol);
        return;
      }
    }

    if (e.target.closest("[data-routine-pin]")) {
      const ids = pinnedIds();
      reorder(routine.position == null ? ids.concat(routine.id) : ids.filter((id) => id !== routine.id));
      return;
    }
    if (e.target.closest("[data-routine-toggle]")) {
      patch(routine, { enabled: !routine.enabled });
      return;
    }
    if (e.target.closest("[data-routine-rename]")) {
      const name = window.prompt("Rename routine", routine.name);
      if (name && name.trim() && name.trim() !== routine.name) patch(routine, { name: name.trim() });
      return;
    }
    if (e.target.closest("[data-routine-group]")) {
      // Which chore boards this routine shows on, as a tap-to-fire circle.
      // Comma-separated; blank removes all. A group named the same as a chore
      // tag puts the two on one board; a name nothing else uses makes a
      // trigger-only one.
      const current = (routine.tags || []).join(", ");
      const next = window.prompt(
        "Board groups — the chore boards this routine appears on, comma-separated (blank to remove):",
        current,
      );
      if (next === null) return;
      if (next.trim() !== current) patch(routine, { tags_csv: next });
      return;
    }
    if (e.target.closest("[data-routine-remove]")) {
      if (!window.confirm(`Delete "${routine.name}"?`)) return;
      try {
        await apiCall(`${indexUrl}/${routine.id}`, "DELETE");
        routines = routines.filter((r) => r.id !== routine.id);
        render();
      } catch (err) {}
    }
  });

  return { refresh };
}
