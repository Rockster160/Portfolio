// Shared custom-icon cropper — file/paste/drop/URL source, canvas crop with a
// square overlay + zoom/pan, optional background removal, name + keywords.
// POSTs a 128px WebP data URL to /chores/icons (a HouseholdIcon), tells the
// shared IconPool so pickers and `hicon:` references see it at once, then
// hands the caller the new `hicon:<id>` reference.
//
// The markup is `app/views/shared/_icon_cropper.html.erb`, rendered once per
// page. Without it on the page `hasIconCropper()` is false and
// `openIconCropper` does nothing, so a caller can fall back to taking the
// image as-is.
//
//   openIconCropper({ source, onSaved })
//     source  — a File, an image URL / data URL string, or null (empty picker)
//     onSaved — called with (ref, row): "hicon:<id>" and the saved pool row
//
// Inline page scripts can't import from the bundle, so the same API is on
// `window.IconCropper`.

import { IconPool } from "./icon_pool";

// Stage 320×320. Crop window 192×192 centred (64px inset). Output 128×128.
const STAGE = 320;
const INSET = 64;
const CROP = 192;
const OUTPUT = 128;

let cropper = null;

function findModal() {
  return document.querySelector("[data-icon-cropper-modal]");
}

// Read on every request rather than once at boot — a service-worker-cached
// shell can carry a stale token, and refreshCsrf() rewrites the meta tag.
function currentCsrf() {
  return document.querySelector("meta[name=\"csrf-token\"]")?.content || "";
}

async function refreshCsrf() {
  try {
    const res = await fetch("/chores/csrf", {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
      redirect: "manual",
    });
    if (!res.ok) return null;

    const data = await res.json();
    if (!data?.token) return null;

    const meta = document.querySelector("meta[name=\"csrf-token\"]");
    if (meta) meta.content = data.token;
    return data.token;
  } catch (_e) {
    return null;
  }
}

// Samples the four output corners (averaged) as the bg colour, then either
// marks every matching pixel transparent (whole-image mode) or flood-fills
// from the border so internal matching pixels — eyes, highlights, glyph
// interiors — survive.
function removeBackground(target, threshold, edgesOnly) {
  const w = target.width;
  const h = target.height;
  const tctx = target.getContext("2d");
  const img = tctx.getImageData(0, 0, w, h);
  const data = img.data;

  // When the user zooms out, the cropped canvas extends past the source image
  // and the outer ring becomes transparent padding. Sampling colour OR seeding
  // the flood fill from those pixels would either pick a (0,0,0) "bg colour"
  // or eat through the padding-to-image transition. Walk each border pixel
  // inward along its ray until we find a pixel actually drawn from the source
  // image (alpha > 0) and treat THAT as the real edge.
  function walkInward(x, y, dx, dy) {
    while (x >= 0 && y >= 0 && x < w && y < h) {
      if (data[(y * w + x) * 4 + 3] > 0) return [x, y];
      x += dx;
      y += dy;
    }
    return null;
  }

  const cornerSamples = [
    walkInward(0, 0, 1, 1),
    walkInward(w - 1, 0, -1, 1),
    walkInward(0, h - 1, 1, -1),
    walkInward(w - 1, h - 1, -1, -1),
  ].filter(Boolean);
  // Whole crop is transparent — nothing to do.
  if (cornerSamples.length === 0) return;

  let br = 0;
  let bg = 0;
  let bb = 0;
  cornerSamples.forEach(([x, y]) => {
    const i = (y * w + x) * 4;
    br += data[i];
    bg += data[i + 1];
    bb += data[i + 2];
  });
  br /= cornerSamples.length;
  bg /= cornerSamples.length;
  bb /= cornerSamples.length;

  // Threshold 0-100 → sum-of-squared-deltas budget across r,g,b.
  const t = (threshold / 100) * 255;
  const budget = t * t * 3;
  function matches(i) {
    // Already-transparent padding never matches: it has no colour to compare
    // against, and treating it as a match would let the flood fill burn
    // through the padding-to-image transition.
    if (data[i + 3] === 0) return false;
    const dr = data[i] - br;
    const dg = data[i + 1] - bg;
    const db = data[i + 2] - bb;
    return dr * dr + dg * dg + db * db <= budget;
  }

  if (edgesOnly) {
    // Flood-fill from every border pixel that matches. Internal matching
    // pixels never connected to the border stay opaque.
    const visited = new Uint8Array(w * h);
    const queue = new Int32Array(w * h);
    let head = 0;
    let tail = 0;
    function tryPush(x, y) {
      if (x < 0 || y < 0 || x >= w || y >= h) return;
      const pi = y * w + x;
      if (visited[pi]) return;
      const i = pi * 4;
      if (!matches(i)) return;
      visited[pi] = 1;
      data[i + 3] = 0;
      queue[tail++] = pi;
    }
    // Seed at the FIRST opaque pixel along each inward ray — the real image
    // edge, which is past any transparent zoom-out ring.
    function seedRay(x0, y0, dx, dy) {
      const start = walkInward(x0, y0, dx, dy);
      if (start) tryPush(start[0], start[1]);
    }
    for (let x = 0; x < w; x++) {
      seedRay(x, 0, 0, 1);
      seedRay(x, h - 1, 0, -1);
    }
    for (let y = 0; y < h; y++) {
      seedRay(0, y, 1, 0);
      seedRay(w - 1, y, -1, 0);
    }
    while (head < tail) {
      const pi = queue[head++];
      const x = pi % w;
      const y = (pi / w) | 0;
      tryPush(x + 1, y);
      tryPush(x - 1, y);
      tryPush(x, y + 1);
      tryPush(x, y - 1);
    }
  } else {
    for (let i = 0; i < data.length; i += 4) {
      if (matches(i)) data[i + 3] = 0;
    }
  }
  tctx.putImageData(img, 0, 0);
}

function bindCropper(modal) {
  const q = (sel) => modal.querySelector(sel);
  const sourcePane = q("[data-cropper-source]");
  const stagePane = q("[data-cropper-stage]");
  const fileBtn = q("[data-cropper-file-btn]");
  const fileInput = q("[data-cropper-file]");
  const urlInput = q("[data-cropper-url]");
  const sourceError = q("[data-cropper-error]");
  const stageError = q("[data-cropper-stage-error]");
  const canvas = q("[data-cropper-canvas]");
  const canvasWrap = q("[data-cropper-canvas-wrap]");
  const zoomInput = q("[data-cropper-zoom]");
  const resetBtn = q("[data-cropper-reset]");
  const nameInput = q("[data-cropper-name]");
  const keysInput = q("[data-cropper-keywords]");
  const saveBtn = q("[data-cropper-save]");
  const saveHint = q("[data-cropper-save-hint]");
  const bgEnable = q("[data-cropper-bg-enable]");
  const bgControls = q("[data-cropper-bg-controls]");
  const bgThreshold = q("[data-cropper-bg-threshold]");
  const bgThresholdValue = q("[data-cropper-bg-threshold-value]");
  const bgEdges = q("[data-cropper-bg-edges]");
  const previewCanvas = q("[data-cropper-preview]");
  const ctx = canvas.getContext("2d");

  let sourceImage = null;
  let onSaved = null;
  let offsetX = 0; // canvas coords of the source's top-left
  let offsetY = 0;
  let baseScale = 1; // "fit" scale derived from source size
  let userZoom = 1; // multiplier from the slider

  function showError(el, msg) {
    el.textContent = msg || "";
    el.classList.toggle("hidden", !msg);
  }

  function setSaveEnabled() {
    const hasImage = !!sourceImage;
    const hasName = (nameInput.value || "").trim().length > 0;
    saveBtn.disabled = !(hasImage && hasName);
    if (!saveHint) return;

    let msg = "";
    if (!hasImage) msg = "Pick an image to continue";
    else if (!hasName) msg = "Add a name to save";
    saveHint.textContent = msg;
    saveHint.classList.toggle("hidden", !msg);
  }

  function clearPreview() {
    previewCanvas.getContext("2d").clearRect(0, 0, previewCanvas.width, previewCanvas.height);
  }

  function resetState() {
    sourceImage = null;
    offsetX = 0;
    offsetY = 0;
    baseScale = 1;
    userZoom = 1;
    zoomInput.value = "1";
    nameInput.value = "";
    keysInput.value = "";
    urlInput.value = "";
    bgEnable.checked = false;
    bgThreshold.value = "20";
    bgThresholdValue.textContent = "20";
    bgEdges.checked = true;
    bgControls.classList.add("hidden");
    showError(sourceError, "");
    showError(stageError, "");
    sourcePane.classList.remove("hidden");
    stagePane.classList.add("hidden");
    clearPreview();
    setSaveEnabled();
  }

  // Shared by the preview thumbnail and the save payload.
  function renderToCanvas(targetCanvas) {
    const w = targetCanvas.width;
    const h = targetCanvas.height;
    const octx = targetCanvas.getContext("2d");
    octx.clearRect(0, 0, w, h);
    if (!sourceImage) return;

    const scale = baseScale * userZoom;
    const srcX = (INSET - offsetX) / scale;
    const srcY = (INSET - offsetY) / scale;
    const srcSize = CROP / scale;
    octx.drawImage(sourceImage, srcX, srcY, srcSize, srcSize, 0, 0, w, h);
    if (bgEnable.checked) {
      removeBackground(targetCanvas, parseInt(bgThreshold.value, 10), bgEdges.checked);
    }
  }

  function renderOutput() {
    const out = document.createElement("canvas");
    out.width = OUTPUT;
    out.height = OUTPUT;
    renderToCanvas(out);

    let url = "";
    try { url = out.toDataURL("image/webp", 0.85); } catch (_e) { /* noop */ }
    if (!url || url.length < 64) url = out.toDataURL("image/png");
    return url;
  }

  // Debounced — cheap to re-render at 96×96.
  let previewTimer = null;
  function schedulePreview() {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(() => renderToCanvas(previewCanvas), 30);
  }

  function draw() {
    ctx.clearRect(0, 0, STAGE, STAGE);
    if (!sourceImage) return;

    const s = baseScale * userZoom;
    ctx.drawImage(sourceImage, offsetX, offsetY, sourceImage.naturalWidth * s, sourceImage.naturalHeight * s);
    schedulePreview();
  }

  function loadDataUrl(dataUrl) {
    showError(sourceError, "");
    const img = new Image();
    img.onload = () => {
      sourceImage = img;
      // Fit the image into the crop window so the visible square is fully
      // covered at the starting zoom of 1, centred within the stage.
      baseScale = Math.max(CROP / img.naturalWidth, CROP / img.naturalHeight);
      userZoom = 1;
      zoomInput.value = "1";
      offsetX = (STAGE - img.naturalWidth * baseScale) / 2;
      offsetY = (STAGE - img.naturalHeight * baseScale) / 2;
      sourcePane.classList.add("hidden");
      stagePane.classList.remove("hidden");
      draw();
      setSaveEnabled();
      setTimeout(() => nameInput.focus(), 0);
    };
    img.onerror = () => showError(sourceError, "Couldn't load that image.");
    img.src = dataUrl;
  }

  // Read as a data URL even for SVG — an <img> needs a URL, not markup.
  function loadFile(file) {
    if (!file || !file.type.startsWith("image/")) {
      showError(sourceError, "Pick an image file.");
      return;
    }
    const reader = new FileReader();
    reader.onload = () => loadDataUrl(reader.result);
    reader.onerror = () => showError(sourceError, "Couldn't read that file.");
    reader.readAsDataURL(file);
  }

  async function loadFromUrl(url) {
    showError(sourceError, "");
    const trimmed = (url || "").trim();
    if (!trimmed) return;
    if (trimmed.startsWith("data:image/")) return loadDataUrl(trimmed);

    // Cross-origin canvas taint protection — fetch the bytes ourselves and
    // convert to a data URL, so the crop can be read back off the canvas.
    try {
      const res = await fetch(trimmed, { mode: "cors" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const blob = await res.blob();
      if (!blob.type.startsWith("image/")) throw new Error("Not an image");

      const reader = new FileReader();
      reader.onload = () => loadDataUrl(reader.result);
      reader.onerror = () => showError(sourceError, "Couldn't read URL response.");
      reader.readAsDataURL(blob);
    } catch (e) {
      showError(sourceError, `Couldn't fetch image: ${e.message}`);
    }
  }

  function close() {
    if (modal.open) modal.close();
    onSaved = null;
    resetState();
  }

  // ---- Source input wiring ----
  fileBtn.addEventListener("click", (e) => {
    e.preventDefault();
    fileInput.click();
  });
  fileInput.addEventListener("change", () => {
    const f = fileInput.files?.[0];
    if (f) loadFile(f);
    fileInput.value = "";
  });
  urlInput.addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    loadFromUrl(urlInput.value);
  });
  urlInput.addEventListener("blur", () => {
    if (urlInput.value.trim()) loadFromUrl(urlInput.value);
  });
  // Bound on the whole dialog so a NEW drop replaces the already-loaded image
  // (the source pane is hidden once the stage opens). Crop/zoom/pan reset;
  // name/keywords/bg settings persist.
  ["dragover", "drop"].forEach((evt) => modal.addEventListener(evt, (e) => {
    e.preventDefault();
    if (evt !== "drop") return;
    const f = Array.from(e.dataTransfer?.files || []).find((x) => x.type.startsWith("image/"));
    if (f) loadFile(f);
  }));
  modal.addEventListener("paste", (e) => {
    const items = Array.from(e.clipboardData?.items || []);
    const item = items.find((it) => it.type.startsWith("image/"));
    if (item) {
      e.preventDefault();
      const f = item.getAsFile();
      if (f) loadFile(f);
      return;
    }
    const text = (e.clipboardData?.getData?.("text/plain") || "").trim();
    if (text.startsWith("data:image/") || text.startsWith("http://") || text.startsWith("https://")) {
      e.preventDefault();
      loadFromUrl(text);
    }
  });

  // ---- Crop interactions ----
  zoomInput.addEventListener("input", () => {
    if (!sourceImage) return;
    // Anchor zoom at the centre of the crop window so the visible subject
    // stays in frame as the user zooms in or out.
    const newZoom = parseFloat(zoomInput.value);
    const anchor = STAGE / 2;
    const ratio = newZoom / userZoom;
    offsetX = anchor - ((anchor - offsetX) * ratio);
    offsetY = anchor - ((anchor - offsetY) * ratio);
    userZoom = newZoom;
    draw();
  });
  resetBtn.addEventListener("click", (e) => {
    e.preventDefault();
    resetState();
  });

  let dragging = false;
  let dragLastX = 0;
  let dragLastY = 0;
  canvasWrap.addEventListener("pointerdown", (e) => {
    if (!sourceImage) return;
    dragging = true;
    dragLastX = e.clientX;
    dragLastY = e.clientY;
    canvasWrap.setPointerCapture(e.pointerId);
  });
  canvasWrap.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    // Scale screen movement to canvas pixels so dragging feels 1:1 however
    // the canvas is laid out.
    const rect = canvasWrap.getBoundingClientRect();
    offsetX += (e.clientX - dragLastX) * (STAGE / rect.width);
    offsetY += (e.clientY - dragLastY) * (STAGE / rect.height);
    dragLastX = e.clientX;
    dragLastY = e.clientY;
    draw();
  });
  ["pointerup", "pointercancel"].forEach((evt) => canvasWrap.addEventListener(evt, (e) => {
    dragging = false;
    try { canvasWrap.releasePointerCapture(e.pointerId); } catch (_e) { /* noop */ }
  }));

  nameInput.addEventListener("input", setSaveEnabled);

  // The controls panel collapses when the master toggle is off so the dialog
  // stays compact in the common case.
  bgEnable.addEventListener("change", () => {
    bgControls.classList.toggle("hidden", !bgEnable.checked);
    schedulePreview();
  });
  bgThreshold.addEventListener("input", () => {
    bgThresholdValue.textContent = bgThreshold.value;
    schedulePreview();
  });
  bgEdges.addEventListener("change", schedulePreview);

  async function postIcon(payload, token) {
    return fetch("/chores/icons", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": token,
      },
      body: payload,
    });
  }

  async function save() {
    showError(stageError, "");
    const payload = JSON.stringify({
      household_icon: {
        name: nameInput.value.trim(),
        keywords: keysInput.value.trim(),
        image_data: renderOutput(),
      },
    });

    let res = await postIcon(payload, currentCsrf());
    if (res.status === 422) {
      const fresh = await refreshCsrf();
      if (fresh) res = await postIcon(payload, fresh);
    }
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      if (body.error === "no_household") {
        showError(stageError, "Join a chore household to save custom icons.");
      } else {
        showError(stageError, (body.errors || ["Save failed"]).join(", "));
      }
      return;
    }

    const row = await res.json();
    // The pool is what resolves `hicon:<id>` to a picture, so it has to know
    // about the upload before the caller writes the reference anywhere.
    await IconPool.refreshCustom();
    const cb = onSaved;
    close();
    if (cb) cb(`hicon:${row.id}`, row);
  }

  saveBtn.addEventListener("click", async (e) => {
    e.preventDefault();
    if (saveBtn.disabled) return;

    saveBtn.disabled = true;
    saveBtn.classList.add("loading");
    try {
      await save();
    } catch (err) {
      showError(stageError, err.message || "Save failed");
    } finally {
      saveBtn.classList.remove("loading");
      setSaveEnabled();
    }
  });

  modal.querySelectorAll("[data-action=\"cancel\"]").forEach((b) => b.addEventListener("click", close));

  // Escape is handled here and stopped, so a page-level Escape handler doesn't
  // also close whatever modal the cropper was opened over.
  modal.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation();
    close();
  });
  modal.addEventListener("cancel", (e) => {
    e.preventDefault();
    close();
  });

  // Backdrop dismissal needs BOTH the press and the release on the backdrop
  // itself, so a drag that starts inside the sheet and ends outside it (a
  // crop pan, a text selection) doesn't throw the work away. A click on the
  // ::backdrop reports the dialog as its target; the sheet fills the dialog.
  let downOnBackdrop = false;
  modal.addEventListener("pointerdown", (e) => { downOnBackdrop = e.target === modal; });
  modal.addEventListener("click", (e) => {
    if (e.target === modal && downOnBackdrop) close();
    downOnBackdrop = false;
  });

  resetState();

  return {
    open({ source = null, onSaved: cb = null } = {}) {
      // Out of whatever container the page rendered it in, so neither that
      // container's cascade nor an ancestor <dialog> reaches it.
      if (modal.parentElement !== document.body) document.body.appendChild(modal);

      resetState();
      onSaved = cb;
      if (!modal.open) modal.showModal();
      if (source instanceof Blob) loadFile(source);
      else if (typeof source === "string" && source) loadFromUrl(source);
    },
    close,
  };
}

function getCropper() {
  if (cropper) return cropper;

  const modal = findModal();
  if (!modal) return null;

  cropper = bindCropper(modal);
  return cropper;
}

export function hasIconCropper() {
  return !!(cropper || findModal());
}

// True when the cropper opened; false when this page doesn't render it.
export function openIconCropper(options = {}) {
  const c = getCropper();
  if (!c) return false;

  c.open(options);
  return true;
}

export function closeIconCropper() {
  cropper?.close();
}

window.IconCropper = { open: openIconCropper, close: closeIconCropper, available: hasIconCropper };
