// Full-screen viewer for an image in the thread.
//
// A doorbell frame in a bubble is a thumbnail of the one thing you opened the
// notification to look at — whether the person at the door is someone you know
// is a question about their face, at whatever size the picture actually has.
// Tapping one opens it fitted to the screen; from there it zooms and it saves.
//
// Deliberately NOT a <dialog>: modals.js closes any open dialog on a document
// click, and this one has to survive dragging across its own backdrop.

// How far in a double-tap goes, and the ceiling for pinch/wheel. Past ~6x a
// phone photo is showing its own compression, so more reach buys nothing.
const MAX_SCALE = 6;
const DOUBLE_TAP_SCALE = 2.5;
const MIN_SCALE = 1;

// Keep the picture's own edges inside the frame it's being shown in.
//
// Exported for its own sake: this is the part with the arithmetic in it, and
// panning that lets an image escape the viewport is the bug that makes a zoom
// feel broken. At scale 1 there is no slack in either axis and the answer is
// always 0 — which is what stops a fitted image drifting when someone swipes.
export function clampPan(offset, imageSize, frameSize, scale) {
  const slack = Math.max(0, (imageSize * scale - frameSize) / 2);
  return Math.min(slack, Math.max(-slack, offset));
}

// Where a double-tap goes next: all the way out if we're zoomed at all,
// otherwise in. "Any zoom at all" rather than "exactly 1" because pinch leaves
// fractional scales behind and a tap after one should still reset.
export function nextScale(current) {
  return current > MIN_SCALE + 0.01 ? MIN_SCALE : DOUBLE_TAP_SCALE;
}

export function clampScale(scale) {
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
}

export function initImageViewer(root) {
  if (!root) return null;

  let overlay = null;
  let img = null;
  let scale = 1;
  let tx = 0;
  let ty = 0;
  // Pointer id -> last known position, so one map serves both drag (one
  // pointer) and pinch (two) without a separate touch path.
  const active = new Map();
  let pinchStart = 0;
  let pinchScale = 1;
  let lastTap = 0;

  function apply() {
    if (!img) return;
    const frame = overlay.getBoundingClientRect();
    tx = clampPan(tx, img.clientWidth, frame.width, scale);
    ty = clampPan(ty, img.clientHeight, frame.height, scale);
    img.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
    overlay.classList.toggle("is-zoomed", scale > MIN_SCALE + 0.01);
  }

  function setScale(next) {
    scale = clampScale(next);
    if (scale === MIN_SCALE) {
      tx = 0;
      ty = 0;
    }
    apply();
  }

  function close() {
    if (!overlay) return;
    overlay.remove();
    overlay = null;
    img = null;
    active.clear();
    document.removeEventListener("keydown", onKey);
  }

  function onKey(e) {
    if (e.key === "Escape") close();
  }

  function build(url, filename) {
    overlay = document.createElement("div");
    overlay.className = "byte-image-viewer";

    const bar = document.createElement("div");
    bar.className = "byte-image-viewer-bar";

    const save = document.createElement("a");
    save.className = "byte-image-viewer-btn";
    save.href = url;
    // Same-origin blob paths, so this really downloads rather than navigating.
    save.download = filename || "image";
    save.textContent = "Save";
    // The bar sits over the image and the backdrop closes on tap — without
    // this, saving closes the viewer out from under the download.
    save.addEventListener("click", (e) => e.stopPropagation());

    const shut = document.createElement("button");
    shut.type = "button";
    shut.className = "byte-image-viewer-btn";
    shut.setAttribute("aria-label", "Close");
    shut.textContent = "✕";
    shut.addEventListener("click", (e) => {
      e.stopPropagation();
      close();
    });

    bar.append(save, shut);

    img = document.createElement("img");
    img.className = "byte-image-viewer-img";
    img.src = url;
    img.alt = filename || "";
    img.draggable = false;

    overlay.append(bar, img);
    document.body.appendChild(overlay);
    document.addEventListener("keydown", onKey);
    wire();
  }

  function distance() {
    const [a, b] = Array.from(active.values());
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  function wire() {
    // Tapping the backdrop closes; tapping the picture does not, so a
    // mis-aimed pan never dismisses what you were looking at.
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) close();
    });

    overlay.addEventListener("pointerdown", (e) => {
      active.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (active.size === 2) {
        pinchStart = distance();
        pinchScale = scale;
      }
      overlay.setPointerCapture?.(e.pointerId);
    });

    overlay.addEventListener("pointermove", (e) => {
      const prev = active.get(e.pointerId);
      if (!prev) return;
      active.set(e.pointerId, { x: e.clientX, y: e.clientY });

      if (active.size === 2 && pinchStart > 0) {
        setScale((distance() / pinchStart) * pinchScale);
        return;
      }
      // One finger only pans when there's somewhere to pan to. Fitted, the
      // gesture belongs to the thread underneath.
      if (scale <= MIN_SCALE + 0.01) return;
      e.preventDefault();
      tx += e.clientX - prev.x;
      ty += e.clientY - prev.y;
      apply();
    });

    const release = (e) => {
      active.delete(e.pointerId);
      if (active.size < 2) pinchStart = 0;
    };
    overlay.addEventListener("pointerup", release);
    overlay.addEventListener("pointercancel", release);

    overlay.addEventListener(
      "wheel",
      (e) => {
        e.preventDefault();
        setScale(scale * (e.deltaY < 0 ? 1.15 : 1 / 1.15));
      },
      { passive: false },
    );

    img.addEventListener("click", (e) => {
      e.stopPropagation();
      const now = Date.now();
      if (now - lastTap < 300) setScale(nextScale(scale));
      lastTap = now;
    });
  }

  // Delegated, because the thread rebuilds its nodes constantly (paintMessageNode,
  // refetchHistory) and a per-image listener would die with every repaint.
  root.addEventListener("click", (e) => {
    const picture = e.target.closest?.(".byte-attachment img");
    if (!picture) return;
    // A selection in progress is someone reading, not someone opening.
    const sel = window.getSelection && window.getSelection();
    if (sel && sel.toString().length > 0) return;
    e.preventDefault();
    scale = 1;
    tx = 0;
    ty = 0;
    build(picture.src, picture.alt);
  });

  return { close };
}
