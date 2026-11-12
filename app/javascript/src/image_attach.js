// Images attached to a piece of text, before it is sent.
//
// Two-phase by design. Picked / pasted / dropped images upload to
// /byte/uploads *up front* (multipart) and only the returned ActiveStorage
// signed id is held per image. Whatever finally sends the text carries those
// ids (`attachment_signed_ids`), so the send itself stays plain: a JSON body,
// a form post, or an entry in Byte's offline queue, none of which could hold a
// File.
//
// The tray renders a thumbnail chip per pending image (with an uploading veil
// + spinner, a failed state, and a remove ✕). On send, `commit()` hands back
// the ready ones and pulls them from the tray, leaving anything still
// uploading behind for a follow-up send.
//
// This is the engine. Byte's composer (pages/byte/attachments.js) and every
// `[data-image-field]` (image_field.js) run on it, so the two pick, paste,
// drop, convert and look the same.

const UPLOAD_URL = "/byte/uploads";
// Mirrors ByteMessage::UPLOADABLE_IMAGE_TYPES. HEIC/HEIF are accepted here
// because that's what iOS hands over from the Files app. The server re-checks
// all of this — the list is just a fast local no.
const ACCEPT = [
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/heic",
  "image/heif",
];
const MAX_BYTES = 25 * 1024 * 1024;

// Formats nothing downstream reads: not OpenAI, not Claude, and no browser but
// Safari. They have to become JPEG before they're any use.
//
// The conversion happens HERE rather than on the server, because Safari is both
// the only thing that produces a HEIC and the only thing that can decode one —
// so the one machine guaranteed to manage it is the phone that took the photo.
// Ubuntu's stock ImageMagick has no heic delegate at all, and building one on
// the app box would be a from-source compile to redo every OS upgrade. Doing it
// here also means no droplet CPU and a far smaller upload off a phone.
// ByteImageNormalizer still backstops this server-side.
const TRANSCODE_TYPES = ["image/heic", "image/heif"];
// Mirrors ByteImageNormalizer's ceilings. Re-encode past the byte threshold
// even when the format is fine — OpenAI rejects a single image over 20MB.
const RECOMPRESS_OVER = 8 * 1024 * 1024;
const MAX_DIMENSION = 2400;
const JPEG_QUALITY = 0.88;

// Whether a drag is carrying files (rather than text or a link).
export function dragsFiles(event) {
  return Array.from(event.dataTransfer?.types || []).includes("Files");
}

// The images on a paste (screenshots, copied images), or none.
export function pastedImages(event) {
  const items = event.clipboardData?.items;
  if (!items) return [];

  return Array.from(items)
    .filter((it) => it.kind === "file" && it.type.startsWith("image/"))
    .map((it) => it.getAsFile())
    .filter(Boolean);
}

// The images on a drop, or none.
export function droppedImages(event) {
  return Array.from(event.dataTransfer?.files || []).filter((f) =>
    f.type.startsWith("image/"),
  );
}

// Lights `target` while files are dragged over any of `zones`, and hands the
// dropped images to `onImages`. A depth counter keeps the highlight steady as
// the drag crosses child elements, each of which fires its own leave.
export function wireDrop({ zones, target, onImages, overClass = "is-dragover" }) {
  let depth = 0;
  const setOver = (on) => target?.classList.toggle(overClass, on);

  zones.filter(Boolean).forEach((zone) => {
    zone.addEventListener("dragenter", (e) => {
      if (!dragsFiles(e)) return;
      e.preventDefault();
      depth += 1;
      setOver(true);
    });
    zone.addEventListener("dragover", (e) => {
      if (dragsFiles(e)) e.preventDefault();
    });
    zone.addEventListener("dragleave", () => {
      depth = Math.max(0, depth - 1);
      if (depth === 0) setOver(false);
    });
    zone.addEventListener("drop", (e) => {
      if (!dragsFiles(e)) return;
      e.preventDefault();
      depth = 0;
      setOver(false);
      const files = droppedImages(e);
      if (files.length) onImages(files);
    });
  });
}

// Images pasted into `input` go to `onImages` instead of pasting a filename.
export function wirePaste(input, onImages) {
  input?.addEventListener("paste", (e) => {
    const images = pastedImages(e);
    if (!images.length) return;

    e.preventDefault();
    onImages(images);
  });
}

// A button that opens the hidden file input, and the input's picks.
export function wirePicker(button, fileInput, onImages) {
  button?.addEventListener("click", () => fileInput?.click());
  fileInput?.addEventListener("change", () => {
    if (fileInput.files?.length) onImages(Array.from(fileInput.files));
    fileInput.value = ""; // allow re-picking the same file
  });
}

export function createImageAttach({ tray, onNotice, onChange } = {}) {
  // Each item: { id, file, content_type, filename, byte_size, objectUrl,
  //              signed_id, state: "uploading"|"ready"|"failed", chip }
  const pending = [];
  // Client-side JPEG conversions still running (see `track`).
  const normalizing = new Set();

  function csrfToken() {
    return (
      document
        .querySelector('meta[name="csrf-token"]')
        ?.getAttribute("content") || ""
    );
  }

  async function refreshCsrf() {
    try {
      const res = await fetch("/byte/csrf", {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return null;
      const j = await res.json();
      if (j?.token) {
        document
          .querySelector('meta[name="csrf-token"]')
          ?.setAttribute("content", j.token);
        return j.token;
      }
    } catch (e) {}
    return null;
  }

  function changed() {
    if (tray) tray.hidden = pending.length === 0;
    onChange?.();
  }

  function notice(msg) {
    if (msg) onNotice?.(msg);
  }

  function addFiles(files) {
    for (const file of files) {
      if (!ACCEPT.includes(file.type)) {
        notice(`Can't attach ${file.name || "that file"} — images only.`);
        continue;
      }
      if (file.size > MAX_BYTES) {
        notice(`${file.name || "That image"} is too big (max 25MB).`);
        continue;
      }
      if (needsNormalizing(file)) track(normalizeThenAdd(file));
      else addOne(file);
    }
  }

  function needsNormalizing(file) {
    return TRANSCODE_TYPES.includes(file.type) || file.size > RECOMPRESS_OVER;
  }

  // Normalize BEFORE the chip is built, so the tray previews the JPEG that
  // actually gets sent — a HEIC objectURL renders as a broken image anywhere
  // but Safari. A failed convert falls through to the original and lets the
  // server have the final say on whether it's storable.
  async function normalizeThenAdd(file) {
    addOne((await toJpeg(file)) ?? file);
  }

  // A conversion has no chip yet, so `pending` can't speak for it. Without this
  // a send during the convert window would see an empty tray and drop the image
  // on the floor.
  function track(promise) {
    normalizing.add(promise);
    promise.finally(() => normalizing.delete(promise));
  }

  // Decode, cap the long edge, re-encode as JPEG. Returns null when the browser
  // can't read the source (a HEIC dragged into Chrome) or the canvas refuses.
  async function toJpeg(file) {
    try {
      // `from-image` keeps EXIF rotation, which a bare canvas draw would drop —
      // otherwise every portrait phone photo arrives sideways.
      const bitmap = await createImageBitmap(file, {
        imageOrientation: "from-image",
      });
      const scale = Math.min(
        1,
        MAX_DIMENSION / Math.max(bitmap.width, bitmap.height),
      );
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(bitmap.width * scale);
      canvas.height = Math.round(bitmap.height * scale);
      canvas
        .getContext("2d")
        .drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      bitmap.close?.();

      const blob = await new Promise((resolve) =>
        canvas.toBlob(resolve, "image/jpeg", JPEG_QUALITY),
      );
      if (!blob) return null;

      const base = (file.name || "image").replace(/\.[^.]+$/, "");
      return new File([blob], `${base}.jpg`, { type: "image/jpeg" });
    } catch (e) {
      return null;
    }
  }

  function addOne(file) {
    const item = {
      id: `att-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      file,
      content_type: file.type,
      filename: file.name || "image",
      byte_size: file.size,
      objectUrl: URL.createObjectURL(file),
      signed_id: null,
      state: "uploading",
    };
    item.chip = buildChip(item);
    pending.push(item);
    tray?.appendChild(item.chip);
    changed();
    // Held so a send arriving mid-upload can wait on it (see `settled`).
    item.promise = upload(item);
  }

  function buildChip(item) {
    const chip = document.createElement("div");
    chip.className = "image-attach-chip is-uploading";
    chip.dataset.attachId = item.id;

    const img = document.createElement("img");
    img.src = item.objectUrl;
    img.alt = item.filename;
    chip.appendChild(img);

    const spin = document.createElement("span");
    spin.className = "image-attach-spin";
    chip.appendChild(spin);

    const rm = document.createElement("button");
    rm.type = "button";
    rm.className = "image-attach-remove";
    rm.setAttribute("aria-label", "Remove image");
    rm.textContent = "✕";
    rm.addEventListener("click", () => remove(item.id));
    chip.appendChild(rm);

    return chip;
  }

  async function upload(item) {
    const form = new FormData();
    form.append("files[]", item.file, item.filename);

    const doFetch = (token) =>
      fetch(UPLOAD_URL, {
        method: "POST",
        credentials: "same-origin",
        headers: { "X-CSRF-Token": token, Accept: "application/json" },
        body: form,
      });

    try {
      let res = await doFetch(csrfToken());
      if (res.status === 401 || res.status === 422) {
        const fresh = await refreshCsrf();
        if (fresh) res = await doFetch(fresh);
      }
      if (!res.ok) return markFailed(item, res);

      const j = await res.json().catch(() => null);
      const a = j?.attachments?.[0];
      if (!a?.signed_id) return markFailed(item);

      item.signed_id = a.signed_id;
      item.content_type = a.content_type || item.content_type;
      if (a.byte_size != null) item.byte_size = a.byte_size;
      item.state = "ready";
      item.chip?.classList.remove("is-uploading");
      changed();
    } catch (e) {
      markFailed(item);
    }
  }

  function markFailed(item, res) {
    item.state = "failed";
    item.chip?.classList.remove("is-uploading");
    item.chip?.classList.add("is-failed");
    changed();
    let msg = "Couldn't upload that image.";
    if (res) {
      // Surface the server's rejection reason (type / size) when it gave one.
      // Best-effort; the chip already shows the failed state regardless.
      res
        .clone()
        .json()
        .then((j) => {
          if (j?.error) notice(`Upload failed: ${j.error}`);
        })
        .catch(() => notice(msg));
    } else {
      notice(msg);
    }
  }

  function remove(id) {
    const idx = pending.findIndex((p) => p.id === id);
    if (idx < 0) return;
    const [item] = pending.splice(idx, 1);
    if (item.objectUrl) URL.revokeObjectURL(item.objectUrl);
    item.chip?.remove();
    changed();
  }

  // ---------- public surface ----------

  function ready() {
    return pending.filter((p) => p.state === "ready" && p.signed_id);
  }

  function hasReady() {
    return ready().length > 0;
  }

  // The signed ids of everything uploaded so far, in the order they were added.
  function readyIds() {
    return ready().map((p) => p.signed_id);
  }

  function isUploading() {
    return normalizing.size > 0 || pending.some((p) => p.state === "uploading");
  }

  // Resolves once everything in flight has landed (or failed). Hitting send
  // while an image is still converting or going up should carry that image, not
  // send the text without it and strand the chip in the tray.
  //
  // Loops because a finished conversion STARTS an upload — one pass would
  // return with the real work just beginning. Both stages always resolve
  // (neither throws), so this drains in two rounds at most.
  async function settled() {
    while (isUploading()) {
      await Promise.allSettled([
        ...normalizing,
        ...pending.map((p) => p.promise).filter(Boolean),
      ]);
    }
  }

  // Take the uploaded (ready) images for a send: returns their signed ids plus
  // preview objects (shaped like attachment wire objects, with the local
  // objectURL as `url`) for an optimistic bubble. The committed chips leave
  // the tray; anything still uploading or failed stays put. The objectURLs are
  // NOT revoked here — a send's optimistic preview still points at them; the
  // caller revokes once the server echoes back the real attachment.
  function commit() {
    const done = ready();
    done.forEach((p) => p.chip?.remove());

    const kept = pending.filter((p) => !done.includes(p));
    pending.length = 0;
    pending.push(...kept);
    changed();

    return {
      signed_ids: done.map((p) => p.signed_id),
      previews: done.map((p) => ({
        id: p.signed_id,
        content_type: p.content_type,
        filename: p.filename,
        url: p.objectUrl,
      })),
    };
  }

  // Only the tray at the start: there's nothing to report yet, and the caller
  // doesn't have this object back to ask about it until we return.
  if (tray) tray.hidden = true;

  return { addFiles, hasReady, readyIds, isUploading, settled, commit };
}
