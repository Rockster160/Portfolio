// Every web link in Byte opens outside it.
//
// Byte is installed with `scope: "/"`, so every page on this site is inside the
// app. iOS keeps an in-scope link in the standalone window even with
// `target="_blank"`, and following one replaces the conversation with a page
// that has no back button. `x-safari-https://` is the scheme iOS hands to
// Safari itself; anywhere else a plain new tab does the job.

const WEB_URL = /^https?:$/;

// What to navigate to so `url` lands outside Byte, or null when `url` is not a
// web link (mailto:, tel:, a bare #anchor) and should keep its own behaviour.
export function outsideHref(url, { iosStandalone = false, base } = {}) {
  let parsed;
  try {
    parsed = new URL(url, base);
  } catch {
    return null;
  }
  if (!WEB_URL.test(parsed.protocol)) return null;

  return iosStandalone ? `x-safari-${parsed.href}` : parsed.href;
}

// `navigator.standalone` only exists on iOS, and is true only when launched
// from the home screen.
function isIosStandalone(win) {
  return win.navigator?.standalone === true;
}

export function openOutside(url, win = window) {
  const iosStandalone = isIosStandalone(win);
  const href = outsideHref(url, { iosStandalone, base: win.location?.href });
  if (!href) return false;

  if (iosStandalone) {
    // A scheme the OS hands to Safari: the page here stays put.
    win.location.href = href;
  } else {
    win.open(href, "_blank", "noopener");
  }
  return true;
}

// The anchor a click should be taken over for, or null. A download stays a
// download, and a link to a spot on this page stays on this page.
export function linkToTakeOver(event, win = window) {
  if (event.defaultPrevented || event.button !== 0) return null;

  const anchor = event.target?.closest?.("a[href]");
  if (!anchor || anchor.hasAttribute("download")) return null;

  const raw = anchor.getAttribute("href") || "";
  if (raw.startsWith("#")) return null;
  if (!outsideHref(anchor.href, { base: win.location?.href })) return null;

  return anchor;
}

// Bubble phase, so a handler that already acted on the click and cancelled it
// (a checklist receipt, a chip) keeps it.
export function initExternalLinks(root = document, win = window) {
  root.addEventListener("click", (event) => {
    const anchor = linkToTakeOver(event, win);
    if (!anchor) return;

    event.preventDefault();
    openOutside(anchor.href, win);
  });
}
