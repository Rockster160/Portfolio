// The board's home-screen icon, chosen in Board settings: any pick from the
// shared icon picker on a flat background colour. The phone draws it into one
// 512px PNG and the server keeps that, since a manifest and an
// apple-touch-icon both want a picture, and the phone already has every emoji,
// glyph font and household upload loaded to draw from.

import { renderIconValue, openIconPicker, loadIconPool } from "../../icon_picker";
import { IconPool } from "../../icon_pool";

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

export function setupAppIcon(row) {
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
    openIconPicker({ onPick: value => { icon = value || ""; paint(); } });
  });
  colorInput.addEventListener("input", paint);
  clearBtn.addEventListener("click", () => {
    icon = "";
    paint();
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
    // The fields for PATCH /quests/:id, or null when the pick couldn't be drawn.
    async payload() {
      if (!icon) return { icon: "", icon_color: "", icon_png: "" };

      const png = await drawAppIcon(icon, colorInput.value);
      if (!png) return null;
      return { icon, icon_color: colorInput.value, icon_png: png };
    },
    saved(next) {
      saved.icon = next.icon || "";
      saved.color = next.icon_color || saved.color;
      document.querySelectorAll("link[data-quests-favicon]").forEach(link => {
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
