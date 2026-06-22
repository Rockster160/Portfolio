// Build an `.agenda-item` DOM row from an AgendaStore item JSON. Clones
// `<template id="agenda-item-template">` (rendered once per page by
// `agenda_items/_template.html.erb`) and fills text + attributes + the
// per-context flags (editable, preview, etc.) so the resulting HTML
// matches what `_item.html.erb` would have rendered server-side.
//
// The data-* attribute payload comes from `item.presentation_attrs` —
// same hash the ERB partial iterates, so the two render paths can't
// drift on which attributes get emitted.
//
// Mirrors the server-side `_item.html.erb` conditional logic:
//   * Location: hidden when blank OR when it's a URL (no map-marker
//     chrome — URLs go straight into the details modal as a link).
//   * Travel block: hidden when both arrive-early and travel minutes
//     are zero; each half (arrive icon / car icon) hides independently.
//   * RSVP slot: shows needs-response or declined badge; otherwise
//     stays empty (slot reserved for vertical alignment).
//   * Recurring slot: badge present only when item is recurring.
//   * Edit slot: pencil present only when editable.

function locationLooksLikeUrl(text) {
  return /^https?:\/\//i.test(String(text || "").trim());
}

// Compact "Nh Mm" formatter for travel/arrive labels. Centralised here
// so every renderer (agenda list rows, cal_week tiles, cal_month items,
// month_view cells) presents long drives the same way. "216m" was
// reading as a single opaque number; "3h 36m" is what a user actually
// parses at a glance.
//
//   45  → "45m"
//   60  → "1h"
//   75  → "1h 15m"
//   216 → "3h 36m"
function fmtMinutes(min) {
  const n = Math.max(0, Number(min) || 0);
  if (n < 60) return `${n}m`;
  const h = Math.floor(n / 60);
  const m = n - h * 60;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

function bool(v) {
  return v === true || v === "true";
}

// Public entry point. Returns a fully populated <div class="agenda-item">
// element ready to append to a section container. Falls back gracefully
// (returns null) if the template isn't on the page or the item is
// missing required fields.
function buildAgendaItem(item, opts = {}) {
  if (!item) return null;
  const tpl = document.getElementById("agenda-item-template");
  if (!tpl || !tpl.content) return null;

  const node = tpl.content.firstElementChild.cloneNode(true);
  const attrs = item.presentation_attrs || {};
  const editable = opts.editable !== false && item.editable !== false;
  const preview = !!opts.preview;

  applyDataAttrs(node, attrs);
  if (!editable) node.setAttribute("data-readonly", "");
  applyClasses(node, item, attrs, { editable: editable, preview: preview });
  applyStyleVars(node, attrs);
  fillTitle(node, item);
  fillCheckbox(node, item, attrs, { editable: editable, preview: preview });
  fillBody(node, attrs);
  fillIcons(node, item, attrs, { editable: editable });

  return node;
}

function applyDataAttrs(node, attrs) {
  for (const key of Object.keys(attrs)) {
    const value = attrs[key];
    node.setAttribute(`data-${key}`, value == null ? "" : String(value));
  }
}

function applyClasses(node, item, attrs, ctx) {
  node.classList.add(`kind-${attrs.kind || "task"}`);
  if (bool(attrs["all-day"])) node.classList.add("all-day");
  if (item.status === "tentative" || item.status === "cancelled") node.classList.add(item.status);
  if (item.crossed_out) node.classList.add("crossed-out");
  if (bool(attrs.recurring)) node.classList.add("recurring");
  if (bool(attrs.phantom)) node.classList.add("phantom");
  if (ctx.preview) node.classList.add("preview");
  if (!ctx.editable && !ctx.preview) node.classList.add("readonly");
  // RSVP state — drives the `.agenda-item-rsvp-slot` badge visibility AND
  // the row's strikethrough on declined items, same as `_item.html.erb`.
  if (item.attendees && Array.isArray(item.attendees)) {
    const inviteCount = item.attendees.length;
    if (inviteCount > 0) node.classList.add("invite");
  }
  const rsvp = attrs["self-response"];
  if (rsvp === "needsAction") node.classList.add("needs-response");
  if (rsvp === "declined") node.classList.add("declined");
}

function applyStyleVars(node, attrs) {
  const color = attrs.color || "";
  const agendaColor = attrs["agenda-color"] || "";
  node.style.setProperty("--item-color", color);
  node.style.setProperty("--agenda-color", agendaColor);
}

function fillTitle(node, item) {
  const agendaName = (item.agenda_name || (item.agenda && item.agenda.name) || "").toString();
  const isPhantom = item.phantom || (item.presentation_attrs && bool(item.presentation_attrs.phantom));
  const idTitle = isPhantom
    ? `Agenda #${item.agenda_id || ""}`
    : `Item #${item.id || ""}`;
  node.setAttribute("title", `${agendaName} · ${idTitle}`);
}

function fillCheckbox(node, item, attrs, ctx) {
  const checkZone = node.querySelector(".agenda-item-check-zone");
  const input = node.querySelector(".agenda-item-check");
  if (!checkZone || !input) return;

  const id = attrs["item-id"] || "";
  input.id = `agenda_item_${id}`;
  if (item.completed_at) input.checked = true;

  const checkDisabled = ctx.preview || !ctx.editable;
  if (checkDisabled) {
    input.disabled = true;
    const reason = ctx.preview
      ? "Tap forward to today to check this off."
      : (!ctx.editable ? "Read-only — only editors can change this." : "");
    if (reason) checkZone.setAttribute("title", reason);
  } else {
    input.setAttribute("data-checked-url", attrs["item-url"] || "");
  }
}

function fillBody(node, attrs) {
  // Time span — `data-time-hydrate` triggers JS to fill from start/end epochs.
  // We seed the hydration attrs so the existing hydrator (time_hydration.js)
  // picks the node up on the next animation frame.
  const timeSpan = node.querySelector(".agenda-item-time");
  if (timeSpan) {
    const allDay = bool(attrs["all-day"]);
    const startEpoch = attrs["start-at"];
    const endEpoch = attrs["end-at"];
    timeSpan.setAttribute("data-start-epoch", startEpoch == null ? "" : startEpoch);
    timeSpan.setAttribute("data-end-epoch", endEpoch == null ? "" : endEpoch);
    timeSpan.setAttribute("data-all-day", allDay ? "true" : "false");
    const isEvent = attrs.kind === "event";
    const fmt = allDay ? "day" : (isEvent && endEpoch ? "range" : "time");
    timeSpan.setAttribute("data-format", fmt);
  }

  const nameSpan = node.querySelector(".agenda-item-name");
  if (nameSpan) nameSpan.textContent = attrs.name || "";

  // Location — show map-marker + text only when present AND not a URL.
  // URL locations appear ONLY in the details modal as a link (mirrors
  // `_item.html.erb` line 88).
  const locSpan = node.querySelector(".agenda-item-loc");
  const location = attrs.location || "";
  if (!location || locationLooksLikeUrl(location)) {
    locSpan?.remove();
  } else {
    const locText = node.querySelector(".agenda-item-loc-text");
    if (locText) locText.textContent = location;
  }

  // Travel block — leave-at time + arrive-early + car drive minutes.
  // Whole block hides when both halves are zero; each half hides
  // independently otherwise (matches the inline conditionals in ERB).
  const travelSpan = node.querySelector(".agenda-item-travel");
  if (!travelSpan) return;
  const travelMin = Number(attrs["travel-minutes"]) || 0;
  const arriveEarlyMin = Number(attrs["arrive-early-minutes"]) || 0;
  if (travelMin <= 0 && arriveEarlyMin <= 0) {
    travelSpan.remove();
    return;
  }
  const startEpoch = Number(attrs["start-at"]) || 0;
  const leaveEpoch = startEpoch - (arriveEarlyMin + travelMin) * 60;
  const leaveSpan = node.querySelector(".agenda-item-travel-leave");
  if (leaveSpan) leaveSpan.setAttribute("data-start-epoch", leaveEpoch);

  const arriveIcon = node.querySelector(".agenda-item-travel-arrive-icon");
  const arriveText = node.querySelector(".agenda-item-travel-arrive-text");
  const carIcon    = node.querySelector(".agenda-item-travel-car-icon");
  const carText    = node.querySelector(".agenda-item-travel-car-text");
  const plus       = node.querySelector(".agenda-item-travel-plus");

  if (arriveEarlyMin > 0) {
    if (arriveText) arriveText.textContent = fmtMinutes(arriveEarlyMin);
  } else {
    arriveIcon?.remove();
    arriveText?.remove();
  }
  if (travelMin > 0) {
    if (carText) carText.textContent = fmtMinutes(travelMin);
  } else {
    carIcon?.remove();
    carText?.remove();
  }
  if (!(arriveEarlyMin > 0 && travelMin > 0)) plus?.remove();
}

function fillIcons(node, item, attrs, ctx) {
  // RSVP slot — needs-response and declined badges are both present in
  // the template; remove whichever doesn't apply (or both if neither).
  const rsvpSlot = node.querySelector(".agenda-item-rsvp-slot");
  if (rsvpSlot) {
    const rsvp = attrs["self-response"];
    const needs = rsvpSlot.querySelector(".needs-response");
    const declined = rsvpSlot.querySelector(".declined");
    if (rsvp === "needsAction") {
      declined?.remove();
    } else if (rsvp === "declined") {
      needs?.remove();
    } else {
      needs?.remove();
      declined?.remove();
    }
  }

  // Recurring badge — present only when recurring.
  if (!bool(attrs.recurring)) {
    node.querySelector(".agenda-item-recurring-badge")?.remove();
  }

  // Edit pencil — only when editable.
  const editSlot = node.querySelector(".agenda-item-edit-slot");
  if (editSlot && !ctx.editable) {
    editSlot.querySelector(".agenda-item-edit")?.remove();
  } else if (editSlot) {
    const editBtn = editSlot.querySelector(".agenda-item-edit");
    if (editBtn) {
      const isPhantom = bool(attrs.phantom);
      const idTitle = isPhantom
        ? `Agenda #${attrs["agenda-id"] || ""}`
        : `Item #${item.id || attrs["item-id"] || ""}`;
      editBtn.setAttribute("title", idTitle);
    }
  }
}

// In-place patch — mutates an EXISTING `.agenda-item` node with the
// latest item data without touching the node identity. Eliminates the
// flicker, focus loss, and scroll jump that `replaceWith(buildAgendaItem(...))`
// causes on every store change.
//
// Granularity: text content via `.textContent`, attribute values via
// `setAttribute`, structural changes (location appears/disappears,
// travel block toggles, RSVP slot swaps) handled per-zone. We never
// re-clone the template here.
//
// Returns the same node it was given so callers can chain.
function patchAgendaItem(node, item, opts = {}) {
  if (!node || !item) return node;
  const attrs = item.presentation_attrs || {};
  const editable = opts.editable !== false && item.editable !== false;
  const preview = !!opts.preview;

  patchDataAttrs(node, attrs);
  patchReadonly(node, editable);
  patchClasses(node, item, attrs, { editable, preview });
  patchStyleVars(node, attrs);
  patchTitle(node, item);
  patchCheckbox(node, item, attrs, { editable, preview });
  patchBody(node, attrs);
  patchIcons(node, item, attrs, { editable });

  return node;
}

function patchDataAttrs(node, attrs) {
  for (const key of Object.keys(attrs)) {
    const value = attrs[key];
    const next = value == null ? "" : String(value);
    if (node.getAttribute(`data-${key}`) !== next) {
      node.setAttribute(`data-${key}`, next);
    }
  }
}

function patchReadonly(node, editable) {
  if (!editable && !node.hasAttribute("data-readonly")) {
    node.setAttribute("data-readonly", "");
  } else if (editable && node.hasAttribute("data-readonly")) {
    node.removeAttribute("data-readonly");
  }
}

function patchClasses(node, item, attrs, ctx) {
  // Clear the dynamic class subset (everything except `.agenda-item`
  // itself + any consumer-added marker) then re-apply. Cheaper than
  // bookkeeping per-class toggles and stays bulletproof against
  // future class additions.
  const dynamicPrefixes = ["kind-", "all-day", "tentative", "cancelled", "crossed-out",
    "recurring", "phantom", "preview", "readonly", "invite", "needs-response", "declined"];
  Array.from(node.classList).forEach((c) => {
    if (c === "agenda-item") return;
    if (dynamicPrefixes.some((p) => c === p || c.startsWith(p + "-") || c === p)) {
      node.classList.remove(c);
    }
  });
  node.classList.add(`kind-${attrs.kind || "task"}`);
  if (bool(attrs["all-day"])) node.classList.add("all-day");
  if (item.status === "tentative" || item.status === "cancelled") node.classList.add(item.status);
  if (item.crossed_out) node.classList.add("crossed-out");
  if (bool(attrs.recurring)) node.classList.add("recurring");
  if (bool(attrs.phantom)) node.classList.add("phantom");
  if (ctx.preview) node.classList.add("preview");
  if (!ctx.editable && !ctx.preview) node.classList.add("readonly");
  if (item.attendees && Array.isArray(item.attendees) && item.attendees.length > 0) {
    node.classList.add("invite");
  }
  const rsvp = attrs["self-response"];
  if (rsvp === "needsAction") node.classList.add("needs-response");
  if (rsvp === "declined") node.classList.add("declined");
}

function patchStyleVars(node, attrs) {
  const color = attrs.color || "";
  const agendaColor = attrs["agenda-color"] || "";
  if (node.style.getPropertyValue("--item-color") !== color) {
    node.style.setProperty("--item-color", color);
  }
  if (node.style.getPropertyValue("--agenda-color") !== agendaColor) {
    node.style.setProperty("--agenda-color", agendaColor);
  }
}

function patchTitle(node, item) {
  const agendaName = (item.agenda_name || (item.agenda && item.agenda.name) || "").toString();
  const isPhantom = item.phantom || (item.presentation_attrs && bool(item.presentation_attrs.phantom));
  const idTitle = isPhantom
    ? `Agenda #${item.agenda_id || ""}`
    : `Item #${item.id || ""}`;
  const next = `${agendaName} · ${idTitle}`;
  if (node.getAttribute("title") !== next) node.setAttribute("title", next);
}

function patchCheckbox(node, item, attrs, ctx) {
  const input = node.querySelector(".agenda-item-check");
  if (!input) return;
  const id = attrs["item-id"] || "";
  const desiredId = `agenda_item_${id}`;
  if (input.id !== desiredId) input.id = desiredId;
  const desiredChecked = !!item.completed_at;
  if (input.checked !== desiredChecked) input.checked = desiredChecked;
  const checkDisabled = ctx.preview || !ctx.editable;
  if (input.disabled !== checkDisabled) input.disabled = checkDisabled;
  if (!checkDisabled) {
    const url = attrs["item-url"] || "";
    if (input.getAttribute("data-checked-url") !== url) {
      input.setAttribute("data-checked-url", url);
    }
  }
}

function patchBody(node, attrs) {
  // Time span — keep data-* in sync, then explicitly re-hydrate. The
  // MutationObserver in agenda.js only watches for added nodes, NOT
  // attribute changes on existing ones, so an in-place patch (e.g.
  // flipping an event to all-day) would leave the text label showing
  // its prior format (e.g. "9:00–10:00") indefinitely without this
  // explicit hydrate call.
  const timeSpan = node.querySelector(".agenda-item-time");
  if (timeSpan) {
    const allDay = bool(attrs["all-day"]);
    const startEpoch = attrs["start-at"];
    const endEpoch = attrs["end-at"];
    setAttrIfChanged(timeSpan, "data-start-epoch", startEpoch == null ? "" : String(startEpoch));
    setAttrIfChanged(timeSpan, "data-end-epoch", endEpoch == null ? "" : String(endEpoch));
    setAttrIfChanged(timeSpan, "data-all-day", allDay ? "true" : "false");
    const isEvent = attrs.kind === "event";
    const fmt = allDay ? "day" : (isEvent && endEpoch ? "range" : "time");
    setAttrIfChanged(timeSpan, "data-format", fmt);
    if (typeof window.__hydrateAgendaTimeNode === "function") {
      window.__hydrateAgendaTimeNode(timeSpan);
    }
  }

  const nameSpan = node.querySelector(".agenda-item-name");
  if (nameSpan && nameSpan.textContent !== (attrs.name || "")) {
    nameSpan.textContent = attrs.name || "";
  }

  // Location structural toggle — present in DOM only when applicable.
  const textWrap = node.querySelector(".agenda-item-text");
  if (textWrap) {
    const location = attrs.location || "";
    const showLoc = location && !locationLooksLikeUrl(location);
    let locSpan = textWrap.querySelector(".agenda-item-loc");
    if (showLoc) {
      if (!locSpan) {
        locSpan = document.createElement("span");
        locSpan.className = "agenda-item-loc";
        locSpan.innerHTML = '<i class="fa fa-map-marker"></i><span class="agenda-item-loc-text"></span>';
        textWrap.appendChild(locSpan);
      }
      const locText = locSpan.querySelector(".agenda-item-loc-text");
      if (locText && locText.textContent !== location) locText.textContent = location;
    } else if (locSpan) {
      locSpan.remove();
    }
  }

  // Travel block structural toggle.
  patchTravelBlock(node, attrs);
}

function patchTravelBlock(node, attrs) {
  const textWrap = node.querySelector(".agenda-item-text");
  if (!textWrap) return;
  const travelMin = Number(attrs["travel-minutes"]) || 0;
  const arriveMin = Number(attrs["arrive-early-minutes"]) || 0;
  let block = textWrap.querySelector(".agenda-item-travel");
  if (travelMin <= 0 && arriveMin <= 0) {
    if (block) block.remove();
    return;
  }
  if (!block) {
    block = document.createElement("span");
    block.className = "agenda-item-travel";
    block.innerHTML = '<span class="agenda-item-travel-leave" data-time-hydrate data-format="cal" data-prefix="→"></span>';
    textWrap.appendChild(block);
  }
  const startEpoch = Number(attrs["start-at"]) || 0;
  const leaveEpoch = startEpoch - (arriveMin + travelMin) * 60;
  const leaveSpan = block.querySelector(".agenda-item-travel-leave");
  if (leaveSpan) {
    setAttrIfChanged(leaveSpan, "data-start-epoch", String(leaveEpoch));
    if (typeof window.__hydrateAgendaTimeNode === "function") {
      window.__hydrateAgendaTimeNode(leaveSpan);
    }
  }

  // Rebuild the icon/text segments — they're trivial spans + i's; cheap
  // and keeps state-toggle complexity contained.
  // Strip EVERY non-leave child before re-adding: that covers both the
  // segments we appended on a prior patch (`.__travel-seg`, `.plus`) AND
  // the template-cloned icons (`.agenda-item-travel-arrive-icon` etc.)
  // that buildAgendaItem leaves in place. Without this, the first patch
  // after build doubles every icon ("[clock]5m+[car]45m[clock]5m+[car]45m").
  Array.from(block.children).forEach((child) => {
    if (child.classList.contains("agenda-item-travel-leave")) return;
    child.remove();
  });

  if (arriveMin > 0) {
    const seg = document.createElement("span");
    seg.className = "__travel-seg";
    seg.innerHTML = `<i class="fa fa-clock-o"></i><span class="agenda-item-travel-text">${fmtMinutes(arriveMin)}</span>`;
    block.appendChild(seg);
  }
  if (arriveMin > 0 && travelMin > 0) {
    const sep = document.createElement("span");
    sep.className = "agenda-item-travel-plus";
    sep.textContent = "+";
    block.appendChild(sep);
  }
  if (travelMin > 0) {
    const seg = document.createElement("span");
    seg.className = "__travel-seg";
    seg.innerHTML = `<i class="fa fa-car"></i><span class="agenda-item-travel-text">${fmtMinutes(travelMin)}</span>`;
    block.appendChild(seg);
  }
}

function patchIcons(node, item, attrs, ctx) {
  const rsvp = attrs["self-response"];
  const rsvpSlot = node.querySelector(".agenda-item-rsvp-slot");
  if (rsvpSlot) {
    rsvpSlot.innerHTML = "";
    if (rsvp === "needsAction") {
      rsvpSlot.innerHTML = '<span class="agenda-item-badge rsvp-badge needs-response" title="Awaiting your response"><i class="fa fa-question-circle"></i></span>';
    } else if (rsvp === "declined") {
      rsvpSlot.innerHTML = '<span class="agenda-item-badge rsvp-badge declined" title="You declined"><i class="fa fa-times-circle"></i></span>';
    }
  }
  const recurringSlot = node.querySelector(".agenda-item-recurring-slot");
  if (recurringSlot) {
    const hasBadge = !!recurringSlot.querySelector(".agenda-item-recurring-badge");
    if (bool(attrs.recurring) && !hasBadge) {
      recurringSlot.innerHTML = '<span class="agenda-item-badge agenda-item-recurring-badge" title="Recurring"><i class="fa fa-refresh"></i></span>';
    } else if (!bool(attrs.recurring) && hasBadge) {
      recurringSlot.innerHTML = "";
    }
  }
  const editSlot = node.querySelector(".agenda-item-edit-slot");
  if (editSlot) {
    const hasBtn = !!editSlot.querySelector(".agenda-item-edit");
    if (ctx.editable && !hasBtn) {
      editSlot.innerHTML = '<button type="button" class="agenda-item-edit" data-edit-item aria-label="Edit"><i class="fa fa-pencil"></i></button>';
    } else if (!ctx.editable && hasBtn) {
      editSlot.innerHTML = "";
    }
  }
}

function setAttrIfChanged(el, name, value) {
  if (el.getAttribute(name) !== value) el.setAttribute(name, value);
}

const AgendaItemRenderer = { buildAgendaItem, patchAgendaItem, fmtMinutes };

if (typeof module !== "undefined" && module.exports) module.exports = AgendaItemRenderer;
if (typeof window !== "undefined") window.AgendaItemRenderer = AgendaItemRenderer;
