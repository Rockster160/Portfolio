// A page's home-screen icon (a quest board, a list or meal builder): any pick
// from the shared icon picker on a flat background colour. The phone draws it into one
// 512px PNG and the server keeps that, since a manifest and an
// apple-touch-icon both want a picture, and the phone already has every emoji,
// glyph font and household upload loaded to draw from.

import { renderIconValue, openIconPicker, loadIconPool } from "./icon_picker";
import { IconPool } from "./icon_pool";
import Rails from "@rails/ujs";

const SIZE = 512;
const GLYPH = 0.62;
const EMOJI_FONT = '"Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif';

function glyphColorOn(hex) {
  const n = parseInt(hex.slice(1), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  return (0.299 * r + 0.587 * g + 0.114 * b) > 160 ? "#111111" : "#ffffff";
}

function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = src;
  });
}

// A Tabler icon is a character in its icon font, put there by `::before`.
async function drawTabler(ctx, value, color) {
  const probe = document.createElement("i");
  probe.className = `ti ${value}`;
  probe.style.cssText = "position:absolute;visibility:hidden;";
  document.body.appendChild(probe);
  const before = getComputedStyle(probe, "::before");
  const char = before.content.replace(/^["']|["']$/g, "");
  const family = before.fontFamily || getComputedStyle(probe).fontFamily;
  probe.remove();
  if (!char || char === "none") return false;

  const font = `${Math.round(SIZE * GLYPH)}px ${family}`;
  try { await document.fonts.load(font, char); } catch (_e) { /* draws with what's loaded */ }
  ctx.font = font;
  ctx.fillStyle = color;
  ctx.fillText(char, SIZE / 2, SIZE / 2);
  return true;
}

async function drawPicture(ctx, src) {
  const img = await loadImage(src);
  const box = SIZE * GLYPH;
  const scale = Math.min(box / img.width, box / img.height);
  const w = img.width * scale;
  const h = img.height * scale;
  ctx.drawImage(img, (SIZE - w) / 2, (SIZE - h) / 2, w, h);
  return true;
}

// The PNG, as a data URL, or null when the value can't be drawn.
export async function drawAppIcon(value, background) {
  const canvas = document.createElement("canvas");
  canvas.width = SIZE;
  canvas.height = SIZE;
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = background;
  ctx.fillRect(0, 0, SIZE, SIZE);
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";

  let drawn = false;
  if (value.startsWith("hicon:")) {
    const src = IconPool.customSrcById(value.slice("hicon:".length));
    drawn = src ? await drawPicture(ctx, src).catch(() => false) : false;
  } else if (value.startsWith("ti-")) {
    drawn = await drawTabler(ctx, value, glyphColorOn(background));
  } else if (value.startsWith("data:image/") || value.startsWith("/")) {
    drawn = await drawPicture(ctx, value).catch(() => false);
  } else {
    // An emoji sits a touch high on its baseline; nudged to look centred.
    ctx.font = `${Math.round(SIZE * GLYPH * 0.9)}px ${EMOJI_FONT}`;
    ctx.fillText(value, SIZE / 2, SIZE * 0.53);
    drawn = true;
  }
  return drawn ? canvas.toDataURL("image/png") : null;
}

// `onChange` runs after each settled change: a pick, a clear, a colour chosen.
export function setupAppIcon(row, { onChange } = {}) {
  const tile = row.querySelector("[data-app-icon-pick]");
  const glyph = row.querySelector("[data-app-icon-glyph]");
  const colorInput = row.querySelector("[data-app-icon-color]");
  const clearBtn = row.querySelector("[data-app-icon-clear]");
  const saved = { icon: row.dataset.icon || "", color: row.dataset.color };
  let icon = saved.icon;

  function paint() {
    tile.style.background = colorInput.value;
    tile.style.color = glyphColorOn(colorInput.value);
    tile.classList.toggle("empty", !icon);
    clearBtn.classList.toggle("hidden", !icon);
    renderIconValue(glyph, icon);
    if (!icon) glyph.textContent = "+";
  }

  tile.addEventListener("click", () => {
    loadIconPool();
    openIconPicker({ onPick: value => { icon = value || ""; paint(); onChange?.(); } });
  });
  colorInput.addEventListener("input", paint);
  colorInput.addEventListener("change", () => onChange?.());
  clearBtn.addEventListener("click", () => {
    icon = "";
    paint();
    onChange?.();
  });

  return {
    reset() {
      icon = saved.icon;
      colorInput.value = saved.color;
      paint();
    },
    changed() {
      return icon !== saved.icon || (icon && colorInput.value !== saved.color);
    },
    // The fields to save, or null when the pick couldn't be drawn.
    async payload() {
      if (!icon) return { icon: "", icon_color: "", icon_png: "" };

      const png = await drawAppIcon(icon, colorInput.value);
      if (!png) return null;
      return { icon, icon_color: colorInput.value, icon_png: png };
    },
    saved(next) {
      saved.icon = next.icon || "";
      saved.color = next.icon_color || saved.color;
      document.querySelectorAll("link[data-app-favicon]").forEach(link => {
        link.href = next.icon_url || link.dataset.defaultHref;
      });
      // Re-read by an install made without reloading the page.
      const manifest = document.querySelector('link[rel="manifest"]');
      if (manifest) {
        const url = new URL(manifest.href, window.location.href);
        url.searchParams.set("v", String(Date.now()));
        manifest.href = url.pathname + url.search;
      }
    },
  };
}

// On a form (a builder's edit page), the pick rides along with the submit:
// drawn when the form is sent, and only when it changed, so an untouched
// picker leaves the saved icon alone.
function setupFormField(row) {
  const form = row.closest("form");
  if (!form) return;

  const appIcon = setupAppIcon(row);
  appIcon.reset();
  const inputs = {};
  row.querySelectorAll("[data-app-icon-input]").forEach(input => {
    inputs[input.dataset.appIconInput] = input;
  });

  form.addEventListener("submit", async (evt) => {
    if (!appIcon.changed()) return;

    evt.preventDefault();
    const payload = await appIcon.payload();
    if (!payload) {
      // UJS disables the submit button a beat after the submit event.
      setTimeout(() => Rails.enableElement(form), 50);
      window.alert("Couldn't draw that icon. Pick another, or clear it.");
      return;
    }
    Object.entries(payload).forEach(([key, value]) => {
      inputs[key].value = value;
      inputs[key].disabled = false;
    });
    form.submit();
  });
}

function bootFormFields() {
  document.querySelectorAll("[data-app-icon-form-field]").forEach(row => {
    if (row.dataset.booted) return;
    row.dataset.booted = "1";
    setupFormField(row);
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootFormFields);
} else {
  bootFormFields();
}
