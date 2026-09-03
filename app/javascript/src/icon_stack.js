// Shared icon field — the little square you type an emoji into.
//
// The chores form has had one of these for a long time, built out of
// `_modals.html.erb` plus ~250 lines inside `_page_script.html.erb` and bound
// to that page's own conventions, which makes it unusable anywhere else. This
// is the same widget as a module: mount it on any `[data-icon-stack]` and it
// reads and writes the reference in that stack's hidden input.
//
// It is the counterpart to `icon_picker.js`, which already did this for the
// BROWSE modal, and it speaks the same vocabulary — an emoji, a `ti-` class, a
// `hicon:` reference, inline SVG, or an image.
//
// Four ways in, all landing on the same value:
//   * type one emoji straight into the square (contenteditable)
//   * paste an emoji, an image, an image URL or SVG markup
//   * drag an image file onto the square
//   * the search chip, which opens the shared picker modal
//
// A caller that wants to do something else with an image — crop it, upload it
// — passes `onImage`; without one, images go in as they arrive.

import { IconPool } from "./icon_pool";
import { renderIconValue, openIconPicker, loadIconPool, onIconPoolChanged } from "./icon_picker";

// Typing is clamped to ONE grapheme cluster. Without it, letters typed into
// the square render at the square's font size — huge scribbles that read as
// the widget being broken. Images and SVG only ever arrive by paste, drop or
// file, never by typing, so the clamp costs nothing.
const segmenter = (typeof Intl !== "undefined" && Intl.Segmenter)
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
  : null;

function firstGrapheme(str) {
  if (!str) return "";
  if (segmenter) {
    for (const piece of segmenter.segment(str)) return piece.segment;
    return "";
  }
  return Array.from(str)[0] || "";
}

function placeCaretAtEnd(el) {
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
}

function isImageUrl(text) {
  return /^https?:\/\/\S+$/i.test(text) || text.startsWith("data:image/");
}

export function bindIconStack(stack, { onImage = null } = {}) {
  if (!stack || stack.__iconStackBound) return null;

  stack.__iconStackBound = true;

  const hidden = stack.querySelector("[data-icon-hidden]");
  const preview = stack.querySelector("[data-icon-preview]");
  const fileInput = stack.querySelector("[data-icon-file]");
  const uploadBtn = stack.querySelector("[data-icon-upload]");
  const pickBtn = stack.querySelector("[data-icon-pick]");
  const clearBtn = stack.querySelector("[data-icon-clear]");

  const render = function () {
    if (!preview) return;

    renderIconValue(preview, hidden ? hidden.value : "");
  };

  // `silent` is for a repaint after the pool changed — the value didn't move,
  // so nobody downstream needs telling.
  const setValue = function (value, { silent = false } = {}) {
    if (hidden) hidden.value = value || "";
    render();
    if (clearBtn) clearBtn.classList.toggle("hidden", !value);
    if (!silent) stack.dispatchEvent(new CustomEvent("icon-stack-change", { bubbles: true, detail: { value: value || "" } }));
  };

  stack.__setIconValue = setValue;
  stack.__iconValue = function () { return hidden ? hidden.value : ""; };

  // An image is the one shape a caller may want to intercept — the interview
  // tracker sends it to a cropper so what gets stored is a 128px square rather
  // than whatever came off the clipboard.
  const takeImage = function (fileOrUrl) {
    if (onImage) return onImage(fileOrUrl);
    if (typeof fileOrUrl === "string") return setValue(fileOrUrl);

    const reader = new FileReader();
    reader.onload = (e) => setValue(e.target.result);
    reader.readAsDataURL(fileOrUrl);
  };

  if (preview) {
    preview.addEventListener("input", () => {
      const glyph = firstGrapheme(preview.textContent || "");
      if (preview.textContent !== glyph) {
        preview.textContent = glyph;
        placeCaretAtEnd(preview);
      }
      if (hidden) hidden.value = glyph;
      if (clearBtn) clearBtn.classList.toggle("hidden", !glyph);
      stack.dispatchEvent(new CustomEvent("icon-stack-change", { bubbles: true, detail: { value: glyph } }));
    });

    // Enter would put a <br> in a box that holds exactly one glyph.
    preview.addEventListener("keydown", (e) => {
      if (e.key === "Enter") e.preventDefault();
    });

    preview.addEventListener("paste", (e) => {
      const items = Array.from(e.clipboardData?.items || []);
      const image = items.find((i) => i.type.startsWith("image/"));
      if (image) {
        e.preventDefault();
        return takeImage(image.getAsFile());
      }

      const text = (e.clipboardData?.getData("text") || "").trim();
      if (!text) return;

      e.preventDefault();
      if (isImageUrl(text) || text.startsWith("<svg")) return takeImage(text);

      setValue(firstGrapheme(text));
    });

    preview.addEventListener("dragover", (e) => {
      e.preventDefault();
      stack.classList.add("is-dropping");
    });
    preview.addEventListener("dragleave", () => stack.classList.remove("is-dropping"));
    preview.addEventListener("drop", (e) => {
      e.preventDefault();
      stack.classList.remove("is-dropping");

      const file = e.dataTransfer?.files?.[0];
      if (file && file.type.startsWith("image/")) return takeImage(file);

      const text = (e.dataTransfer?.getData("text") || "").trim();
      if (isImageUrl(text)) takeImage(text);
    });
  }

  if (uploadBtn && fileInput) {
    uploadBtn.addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", () => {
      const file = fileInput.files[0];
      if (file) takeImage(file);
      fileInput.value = "";
    });
  }

  if (pickBtn) {
    pickBtn.addEventListener("click", () => {
      openIconPicker({ onPick: (value) => setValue(value) });
    });
  }

  if (clearBtn) {
    clearBtn.addEventListener("click", () => setValue(""));
  }

  render();
  if (clearBtn) clearBtn.classList.toggle("hidden", !(hidden && hidden.value));

  // A `hicon:` is a POINTER. If the household deletes that upload the square
  // is showing something that no longer exists, so repaint when the pool moves.
  onIconPoolChanged(() => render());

  return { setValue, render };
}

// Mount every stack under `root`. Pulls the pool first so a stored `hicon:`
// resolves on the first paint rather than appearing a moment later.
export function bindIconStacks(root, options = {}) {
  const stacks = Array.from(root?.querySelectorAll?.("[data-icon-stack]") || []);
  if (stacks.length === 0) return [];

  const bound = stacks.map((stack) => bindIconStack(stack, options)).filter(Boolean);
  loadIconPool().then(() => bound.forEach((s) => s.render()));
  return bound;
}

export { IconPool };
