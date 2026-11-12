// A text field that takes images: `[data-image-field]` around a textarea,
// drawn by app/views/shared/_image_field.html.erb.
//
// Three ways in, all equal: the paperclip in the field's corner, dropping
// images onto the field, and pasting one into the text. Each image uploads as
// soon as it's added (image_attach.js) and becomes a hidden
// `attachment_signed_ids[]` input in the form, so the form posts the way any
// form does. A submit while something is still uploading waits for it rather
// than going without it.

import {
  createImageAttach,
  wireDrop,
  wirePaste,
  wirePicker,
} from "./image_attach";

const NOTICE_FOR = 4000;

export function mountImageField(field) {
  if (field.dataset.imageFieldMounted) return null;
  field.dataset.imageFieldMounted = "true";

  const textarea = field.querySelector("textarea");
  const ids = field.querySelector("[data-image-field-ids]");
  const notice = field.querySelector("[data-image-field-notice]");
  const name = field.dataset.imageField || "attachment_signed_ids[]";
  let noticeTimer = null;

  const say = (msg) => {
    if (!notice) return;
    notice.textContent = msg;
    notice.hidden = false;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => { notice.hidden = true; }, NOTICE_FOR);
  };

  const attach = createImageAttach({
    tray: field.querySelector("[data-image-field-tray]"),
    onNotice: say,
    onChange: () => {
      if (!ids) return;
      ids.replaceChildren(...attach.readyIds().map((signedId) => {
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = name;
        input.value = signedId;
        return input;
      }));
    },
  });

  wirePicker(
    field.querySelector("[data-image-field-pick]"),
    field.querySelector("[data-image-field-file]"),
    attach.addFiles,
  );
  wirePaste(textarea, attach.addFiles);
  wireDrop({ zones: [field], target: field, onImages: attach.addFiles });

  // Clicking the empty part of the box (under the text, beside the tray) puts
  // the cursor in the text, the way it would in a plain textarea.
  field.addEventListener("click", (e) => {
    if (e.target === field) textarea?.focus();
  });

  const form = field.closest("form");
  form?.addEventListener("submit", async (e) => {
    if (!attach.isUploading()) return;

    e.preventDefault();
    e.stopImmediatePropagation();
    await attach.settled();
    form.requestSubmit(e.submitter || undefined);
  }, true);

  return attach;
}

export function mountImageFields(root = document) {
  root.querySelectorAll("[data-image-field]").forEach(mountImageField);
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => mountImageFields());
  } else {
    mountImageFields();
  }
}
