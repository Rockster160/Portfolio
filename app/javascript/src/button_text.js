// What a task's tile says on its button: plain text, `[stack 🔔💤]` (the
// glyphs drawn on top of each other), or text with `[hicon name]` household
// icons in it. Shared by the list pages' task buttons and the board's.

import { HouseholdIconPool } from "./household_icon_pool";

export const splitGraphemes = (s) => {
  if (globalThis.Intl?.Segmenter) {
    const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    return Array.from(seg.segment(s), (x) => x.segment);
  }
  return Array.from(s);
};

const HICON_RX = /\[hicon (.*?)\]/gi;

export const setButtonText = (titleEl, text) => {
  const stackMatch = text.match(/^\[stack (.+)\]$/);
  if (stackMatch) {
    const graphemes = splitGraphemes(stackMatch[1].trim());
    titleEl.textContent = "";
    const stack = document.createElement("i");
    stack.className = "stacked-emoji";
    graphemes.forEach((g) => {
      const span = document.createElement("span");
      span.textContent = g;
      stack.appendChild(span);
    });
    titleEl.appendChild(stack);
  } else if (HICON_RX.test(text)) {
    // innerHTML is only safe once we've escaped the non-hicon parts —
    // broadcast text can be arbitrary and could otherwise inject markup.
    HICON_RX.lastIndex = 0;
    const escape = (s) =>
      s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    let out = "";
    let cursor = 0;
    text.replace(HICON_RX, (match, name, offset) => {
      out += escape(text.slice(cursor, offset));
      out += HouseholdIconPool.markupHtml(name);
      cursor = offset + match.length;
      return match;
    });
    out += escape(text.slice(cursor));
    titleEl.innerHTML = out;
  } else {
    titleEl.textContent = text;
  }
};
