// Long-press (touch) / right-click (desktop) context menu on a message
// bubble. Two actions — Copy ID, Copy full message — plus the id shown
// verbatim so it can be read or hand-selected if the clipboard write is
// blocked (non-secure context, denied permission, etc.).
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

export function initMessageContextMenu(thread, root) {
  if (!thread || !root) return;

  let menu = null;
  let pressTimer = null;
  let startX = 0;
  let startY = 0;
  // Set the instant a long-press fires so the click / selection that the OS
  // synthesises right after doesn't fall through to the bubble.
  let longFired = false;

  const LONG_PRESS_MS = 480;
  const MOVE_CANCEL_PX = 10;

  function buildMenu() {
    const el = document.createElement("div");
    el.className = "byte-msg-menu";
    el.hidden = true;
    el.innerHTML = `
      <div class="byte-msg-menu-id">
        <span class="byte-msg-menu-id-label">Message ID</span>
        <code class="byte-msg-menu-id-value" data-menu-id>—</code>
      </div>
      <button type="button" class="byte-msg-menu-item" data-menu-copy-id>Copy ID</button>
      <button type="button" class="byte-msg-menu-item" data-menu-copy-full>Copy full message</button>
    `;
    root.appendChild(el);

    // Taps inside the menu must not bubble out to the document handler that
    // closes it.
    el.addEventListener("pointerdown", (e) => e.stopPropagation());
    el.addEventListener("click", (e) => e.stopPropagation());

    el.querySelector("[data-menu-copy-id]").addEventListener("click", (e) => {
      runCopy(e.currentTarget, menu.dataset.msgId || "");
    });
    el.querySelector("[data-menu-copy-full]").addEventListener("click", (e) => {
      runCopy(e.currentTarget, menu.dataset.msgFull || "");
    });
    return el;
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

    // Reset button labels/state from any prior open.
    menu.querySelectorAll(".byte-msg-menu-item").forEach((b) => {
      b.classList.remove("is-ok", "is-err");
    });
    menu.querySelector("[data-menu-copy-id]").textContent = "Copy ID";
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
    const node = pressableMessage(e.target);
    if (!node) return;
    longFired = false;
    startX = e.clientX;
    startY = e.clientY;
    cancelPress();
    pressTimer = setTimeout(() => {
      pressTimer = null;
      longFired = true;
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
  // finger during a press — only while a press is pending / just fired, so
  // normal selection elsewhere is untouched.
  document.addEventListener("selectstart", (e) => {
    if (pressTimer || longFired) e.preventDefault();
  });

  // Desktop right-click + Android long-press both surface here.
  thread.addEventListener("contextmenu", (e) => {
    const node = pressableMessage(e.target);
    if (!node) return;
    e.preventDefault();
    openMenu(node, e.clientX, e.clientY);
  });
}
