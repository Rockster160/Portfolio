// Composer image attachments for Byte: the shared engine (../../image_attach)
// wired to the composer's own button, its textarea for pastes, and the whole
// thread plus composer as the drop target.

import {
  createImageAttach,
  wireDrop,
  wirePaste,
  wirePicker,
} from "../../image_attach";

export function initComposerAttachments({
  composer,
  input,
  thread,
  tray,
  fileInput,
  attachBtn,
  onNotice,
}) {
  const attach = createImageAttach({ tray, onNotice });

  wirePicker(attachBtn, fileInput, attach.addFiles);
  wirePaste(input, attach.addFiles);
  wireDrop({ zones: [composer, thread], target: composer, onImages: attach.addFiles });

  return {
    hasReady: attach.hasReady,
    isUploading: attach.isUploading,
    settled: attach.settled,
    commit: attach.commit,
  };
}
