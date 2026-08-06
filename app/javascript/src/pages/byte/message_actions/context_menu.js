// Long-press (touch) / right-click (desktop) context menu on a message
// bubble. Two actions — Copy ID, Copy full message — plus a header showing
// the message's id (verbatim + hand-selectable if the clipboard write is
// blocked in a non-secure context or on denied permission) and its send time.
//
// One reusable menu node is mounted lazily and repositioned per open; the
// target's id + raw body are read off the bubble's dataset (paintMessageNode
// stamps `data-message-id` and `data-full-body`).

// Write to the clipboard with a graceful fallback for browsers / contexts
// where the async Clipboard API is unavailable or rejected (e.g. http, or
// permission denied). Returns true on success.
async function writeClipboard(text) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch (_e) {
    // fall through to the execCommand path
  }
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "0";
    ta.style.left = "0";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    ta.setSelectionRange(0, ta.value.length);
    const ok = document.execCommand("copy");
    ta.remove();
    return ok;
  } catch (_e) {
    return false;
  }
}

// The bubble stamps its send time as an ISO string in `data-created-at`
// (see paintMessageNode). Render it in the viewer's own locale + timezone on
// a 12-hour clock — same convention as the bubble's time label, but with the
// date included since a right-click can land on a message from any day.
const sentFmt = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
  timeStyle: "medium", // "medium" includes seconds (1:37:23 PM); "short" omits them
});
function formatSent(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return sentFmt.format(d);
}

export function initMessageContextMenu(thread, root) {
  if (!thread || !root) return;

  let menu = null;
  let pressTimer = null;
  let startX = 0;
  let startY = 0;
  // Set the instant a long-press fires so the click the OS synthesises right
  // after doesn't fall through to the bubble.
  let longFired = false;
  // When the selection guard below stops caring. A TIMESTAMP rather than a
  // flag, because the thing being suppressed is a moment — the selection iOS
  // starts under the finger — and a flag has to be turned off by something.
  // Nothing reliably did: `longFired` was only cleared by tapping a bubble or
  // by a click reaching the thread, so a menu dismissed any other way (a menu
  // item, Escape, a tap on the composer) left it set, and the guard then
  // cancelled every selection on the page until you happened to tap a message
  // again. That is the "can't select anything, anywhere" bug.
  let guardUntil = 0;

  const LONG_PRESS_MS = 480;
  const MOVE_CANCEL_PX = 10;
  // How long after a long-press fires the selection guard stays up. Only has to
  // outlast the selection iOS synthesises under the finger, which is immediate.
  const GUARD_TAIL_MS = 400;

  function buildMenu() {
    const el = document.createElement("div");
    el.className = "byte-msg-menu";
    el.hidden = true;
    el.innerHTML = `
      <div class="byte-msg-menu-id">
        <span class="byte-msg-menu-id-label">Message ID</span>
        <div class="byte-msg-menu-id-row">
          <code class="byte-msg-menu-id-value" data-menu-id>—</code>
          <button type="button" class="byte-msg-menu-copy" data-menu-copy-id
                  aria-label="Copy message ID" title="Copy ID">
            <svg class="icon-copy" viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
              <path fill="currentColor" d="M16 1H4a2 2 0 0 0-2 2v12h2V3h12V1Zm3 4H8a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2Zm0 16H8V7h11v14Z"/>
            </svg>
            <svg class="icon-check" viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
              <path fill="currentColor" d="M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>
            </svg>
          </button>
        </div>
        <span class="byte-msg-menu-sent" data-menu-sent hidden></span>
      </div>
      <button type="button" class="byte-msg-menu-item" data-menu-copy-full>Copy full message</button>
    `;
    root.appendChild(el);

    // Taps inside the menu must not bubble out to the document handler that
    // closes it.
    el.addEventListener("pointerdown", (e) => e.stopPropagation());
    el.addEventListener("click", (e) => e.stopPropagation());

    el.querySelector("[data-menu-copy-id]").addEventListener("click", (e) => {
      runIconCopy(e.currentTarget, menu.dataset.msgId || "");
    });
    el.querySelector("[data-menu-copy-full]").addEventListener("click", (e) => {
      runCopy(e.currentTarget, menu.dataset.msgFull || "");
    });
    return el;
  }

  // Icon-button copy (the id): swap the copy glyph for a check on success via
  // a state class — the button has no text label to flip like runCopy does.
  async function runIconCopy(btn, text) {
    const ok = await writeClipboard(text);
    btn.classList.toggle("is-ok", ok);
    btn.classList.toggle("is-err", !ok);
    if (ok) {
      setTimeout(closeMenu, 650);
    } else {
      // Leave the menu open so the id above stays hand-selectable; clear the
      // error tint after a beat.
      setTimeout(() => btn.classList.remove("is-err"), 2200);
    }
  }

  async function runCopy(btn, text) {
    const label = btn.textContent;
    const ok = await writeClipboard(text);
    btn.textContent = ok ? "Copied ✓" : "Copy failed — select above";
    btn.classList.toggle("is-ok", ok);
    btn.classList.toggle("is-err", !ok);
    if (ok) {
      // Brief confirmation, then dismiss so the menu doesn't linger.
      setTimeout(closeMenu, 650);
    } else {
      // Leave the menu open on failure so the id above stays hand-selectable;
      // restore the label after a moment.
      setTimeout(() => {
        btn.textContent = label;
        btn.classList.remove("is-err");
      }, 2200);
    }
  }

  function positionMenu(x, y) {
    // Render first (still hidden-less) to measure, then clamp within the
    // viewport with an 8px gutter.
    const gutter = 8;
    const rect = menu.getBoundingClientRect();
    let left = x;
    let top = y;
    if (left + rect.width + gutter > window.innerWidth) {
      left = window.innerWidth - rect.width - gutter;
    }
    if (top + rect.height + gutter > window.innerHeight) {
      top = window.innerHeight - rect.height - gutter;
    }
    menu.style.left = `${Math.max(gutter, left)}px`;
    menu.style.top = `${Math.max(gutter, top)}px`;
  }

  function openMenu(node, x, y) {
    if (!menu) menu = buildMenu();
    const id = node.dataset.messageId || "";
    const full =
      node.dataset.fullBody ??
      node.querySelector("[data-body]")?.innerText ??
      "";
    menu.dataset.msgId = id;
    menu.dataset.msgFull = full;
    menu.querySelector("[data-menu-id]").textContent = id || "—";

    const sent = formatSent(node.dataset.createdAt);
    const sentEl = menu.querySelector("[data-menu-sent]");
    sentEl.textContent = sent ? `Sent ${sent}` : "";
    sentEl.hidden = !sent;

    // Reset button labels/state from any prior open.
    menu.querySelectorAll(".byte-msg-menu-item").forEach((b) => {
      b.classList.remove("is-ok", "is-err");
    });
    menu.querySelector("[data-menu-copy-id]").classList.remove("is-ok", "is-err");
    menu.querySelector("[data-menu-copy-full]").textContent = "Copy full message";

    menu.hidden = false;
    positionMenu(x, y);
    bindDismiss();
  }

  function closeMenu() {
    if (menu && !menu.hidden) {
      menu.hidden = true;
      unbindDismiss();
    }
    // Whatever dismissed it, the gesture is over. Left set, the next click in
    // the thread gets swallowed for no reason.
    longFired = false;
  }

  function onDocPointerDown() {
    closeMenu();
  }
  function onKeyDown(e) {
    if (e.key === "Escape") closeMenu();
  }
  function bindDismiss() {
    document.addEventListener("pointerdown", onDocPointerDown);
    document.addEventListener("keydown", onKeyDown);
    // Any scroll of the thread or a resize invalidates the anchor position.
    thread.addEventListener("scroll", closeMenu, { passive: true });
    window.addEventListener("resize", closeMenu);
  }
  function unbindDismiss() {
    document.removeEventListener("pointerdown", onDocPointerDown);
    document.removeEventListener("keydown", onKeyDown);
    thread.removeEventListener("scroll", closeMenu);
    window.removeEventListener("resize", closeMenu);
  }

  // Don't hijack presses that land on an interactive control inside the
  // bubble (cancel ✕, proposal checkboxes, links, the thoughts toggle).
  function pressableMessage(target) {
    if (target.closest("button, a, input, label, summary, .byte-msg-action-row"))
      return null;
    return target.closest(".byte-msg");
  }

  function cancelPress() {
    if (pressTimer) {
      clearTimeout(pressTimer);
      pressTimer = null;
    }
  }

  // Touch / pen: hold to open. Mouse is handled by `contextmenu` (right-click)
  // so desktop text-selection drags are never interrupted by a press timer.
  thread.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse") return;
    // Reset before the pressable check, not after: a press that lands on a
    // button inside a bubble still ends the previous gesture.
    longFired = false;
    const node = pressableMessage(e.target);
    if (!node) return;
    startX = e.clientX;
    startY = e.clientY;
    cancelPress();
    pressTimer = setTimeout(() => {
      pressTimer = null;
      longFired = true;
      guardUntil = Date.now() + GUARD_TAIL_MS;
      openMenu(node, startX, startY);
    }, LONG_PRESS_MS);
  });

  thread.addEventListener("pointermove", (e) => {
    if (!pressTimer) return;
    if (
      Math.abs(e.clientX - startX) > MOVE_CANCEL_PX ||
      Math.abs(e.clientY - startY) > MOVE_CANCEL_PX
    ) {
      cancelPress();
    }
  });
  ["pointerup", "pointercancel", "pointerleave"].forEach((ev) =>
    thread.addEventListener(ev, cancelPress),
  );

  // Stop the OS-synthesised click that follows a long-press from activating
  // whatever was under the finger.
  thread.addEventListener(
    "click",
    (e) => {
      if (longFired) {
        e.preventDefault();
        e.stopPropagation();
        longFired = false;
      }
    },
    true,
  );

  // Suppress the touch text-selection that would otherwise start under the
  // finger during a press. Bound to the THREAD, not the document: a press on a
  // bubble has no business cancelling a selection in the composer, and this
  // listener sitting on the document is half of why it did.
  thread.addEventListener("selectstart", (e) => {
    if (pressTimer || Date.now() < guardUntil) e.preventDefault();
  });

  // Desktop right-click + Android long-press both surface here.
  thread.addEventListener("contextmenu", (e) => {
    const node = pressableMessage(e.target);
    if (!node) return;
    e.preventDefault();
    openMenu(node, e.clientX, e.clientY);
  });
}
