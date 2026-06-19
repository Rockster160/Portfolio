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
    if (arriveText) arriveText.textContent = `${arriveEarlyMin}m`;
  } else {
    arriveIcon?.remove();
    arriveText?.remove();
  }
  if (travelMin > 0) {
    if (carText) carText.textContent = `${travelMin}m`;
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

const AgendaItemRenderer = { buildAgendaItem };

if (typeof module !== "undefined" && module.exports) module.exports = AgendaItemRenderer;
if (typeof window !== "undefined") window.AgendaItemRenderer = AgendaItemRenderer;
