// One step of a routine, as a form and as a payload.
//
// Split out of routines.js so it can be run without a DOM: the field HTML and
// the reading-back are where a step gets quietly malformed, and everything else
// in that file is wiring. The panel owns the elements; this owns what a typed
// argument looks like and what it turns into.
//
// The shapes come from the tool registry over /buddy/routines/tools — key,
// type, required, values, description — so nothing here decides what a tool
// takes. The server checks the payload again anyway, through the same
// Buddy::Routines.sanitize a routine saved in conversation goes through; this
// exists so the obvious mistakes are caught in front of the person making them,
// and so a time means what they picked.
//
// One shape IS decided here, because it is about typing rather than about the
// tool: a duration is a single box taking the shorthand every other duration
// box in the app takes, and `parseDuration` is that same parser.

import { parseDuration, humanizeSeconds } from "../../timers/duration.js";

// What a duration box accepts, said in the box itself. The readback under it is
// the proof it was understood.
export const DURATION_PLACEHOLDER = "4m · 4m30s · 1h30m · 4:30";

export function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export function escapeAttr(s) {
  return escapeHtml(s).replace(/"/g, "&quot;");
}

export function argLabel(arg) {
  return String(arg.key).replace(/_/g, " ");
}

// An enum is a select because the spelling IS the argument; a boolean is a
// checkbox, because "true" typed into a box works right up until somebody
// writes "yes"; a number gets a numeric keypad on a phone. Everything else is
// text, and the hint under it is the registry's own wording.
export function controlFor(arg) {
  const common = `data-arg-key="${escapeAttr(arg.key)}" data-arg-type="${escapeAttr(arg.type)}"`;

  if (arg.type === "enum" && arg.values) {
    const blank = arg.required ? "" : `<option value=""></option>`;
    const opts = arg.values
      .map((v) => `<option value="${escapeAttr(v)}">${escapeHtml(v)}</option>`)
      .join("");
    return `<select class="byte-modal-input" ${common}>${blank}${opts}</select>`;
  }
  if (arg.type === "duration") {
    return `<input type="text" class="byte-modal-input" inputmode="text" autocomplete="off" ` +
      `spellcheck="false" placeholder="${escapeAttr(DURATION_PLACEHOLDER)}" ${common}>`;
  }
  if (arg.type === "boolean") {
    return `<input type="checkbox" class="byte-arg-check" ${common}>`;
  }
  if (arg.type === "integer" || arg.type === "duration_min") {
    return `<input type="number" class="byte-modal-input" min="0" inputmode="numeric" ${common}>`;
  }
  if (arg.type === "iso_time") {
    return `<input type="datetime-local" class="byte-modal-input" ${common}>`;
  }
  return `<input type="text" class="byte-modal-input" autocomplete="off" ${common}>`;
}

// A checkbox reads the wrong way round stacked — the box lands underneath its
// own name, with the hint beside it — so it goes in front of the text instead.
export function fieldFor(arg) {
  const name = escapeHtml(argLabel(arg));
  const req = arg.required ? `<span class="byte-arg-req" title="Required">*</span>` : "";
  const hint = arg.description ? `<span class="byte-arg-hint">${escapeHtml(arg.description)}</span>` : "";

  if (arg.type === "boolean") {
    return `<label class="byte-arg byte-arg-inline">${controlFor(arg)}` +
      `<span class="byte-arg-text"><span class="byte-arg-name">${name}${req}</span>${hint}</span></label>`;
  }
  // A duration carries a live readback as well as its hint: "4m30" meaning four
  // and a half minutes is only obvious once something says so, and a box that
  // can't read what was typed has to say that while it can still be fixed.
  const read = arg.type === "duration"
    ? `<span class="byte-arg-read" data-arg-read="${escapeAttr(arg.key)}" aria-live="polite"></span>`
    : "";

  return `<label class="byte-arg byte-modal-label">` +
    `<span class="byte-arg-name">${name}${req}</span>${controlFor(arg)}${read}${hint}</label>`;
}

// The line under a duration box: what it was understood as, or that it wasn't.
// Blank reads as blank — most of these open empty and a required one is caught
// on the way out, not scolded while it's still being typed.
export function durationRead(raw) {
  const text = String(raw ?? "").trim();
  if (!text) return "";

  const seconds = parseDuration(text);
  return seconds == null ? "Can't read that as a length" : humanizeSeconds(seconds);
}

// What the fields hold, as the payload a step is made of. `valueOf` hands back
// `{ value, checked }` for one argument, or null when its field isn't there.
//
// A blank OPTIONAL field is left out rather than sent empty: the server reads a
// blank as missing, and an argument nobody filled in is one they didn't mean to
// set. A blank required one is named back to them instead of being sent for the
// server to refuse.
export function readPayload(args, valueOf) {
  const payload = {};
  const missing = [];

  (args || []).forEach((arg) => {
    const field = valueOf(arg);
    if (!field) return;

    if (arg.type === "boolean") {
      if (field.checked) payload[arg.key] = true;
      return;
    }

    const raw = String(field.value ?? "").trim();
    if (!raw) {
      if (arg.required) missing.push(argLabel(arg));
      return;
    }

    // One box, whichever unit the argument wanted. `minutes` is rounded rather
    // than truncated: "90s" on a minutes argument is nearer 2 than 1, and a
    // duration rounding down to zero would be sent as no duration at all.
    if (arg.type === "duration") {
      const seconds = parseDuration(raw);
      if (seconds == null) {
        missing.push(argLabel(arg));
        return;
      }
      payload[arg.key] = arg.unit === "minutes" ? Math.max(1, Math.round(seconds / 60)) : seconds;
      return;
    }

    // A local datetime goes up as a full instant with the offset applied.
    // Sending "2026-10-14T11:00" on its own leaves the zone to be guessed at
    // the other end, which is how a time lands six hours out.
    if (arg.type === "iso_time") {
      const when = new Date(raw);
      if (Number.isNaN(when.getTime())) {
        missing.push(argLabel(arg));
        return;
      }
      payload[arg.key] = when.toISOString();
      return;
    }

    payload[arg.key] = arg.type === "integer" || arg.type === "duration_min" ? Number(raw) : raw;
  });

  return { payload, missing };
}

// The same argument the server's step_phrase leads with, for the same reason:
// "complete chore" twice over says nothing about which two steps those are.
export function stepPhrase(step) {
  const p = step.payload || {};
  const detail = p.name || p.chore || p.item || p.command || p.message || p.title;
  const label = String(step.tool_name).replace(/_/g, " ");
  return detail ? `${label}: ${detail}` : label;
}
