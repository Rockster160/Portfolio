// Small helpers shared by every Games page.

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" };

// Player and game names are typed by hand and go straight into innerHTML.
export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

export function uuid() {
  return (crypto.randomUUID && crypto.randomUUID()) || `g-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export function clock(startedAt) {
  if (!startedAt) return "0:00";
  const secs = Math.max(0, Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000));
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}

export function ago(iso) {
  const secs = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (secs < 5) return "now";
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  return `${Math.floor(secs / 3600)}h`;
}

export function minutesLabel(mins) {
  const n = parseInt(mins, 10);
  if (Number.isNaN(n) || n <= 0) return "";
  const h = Math.floor(n / 60);
  const m = n % 60;
  if (h === 0) return `${m} min`;
  return m ? `${h}h ${m}m` : `${h}h`;
}

export function buzz(ms = 12) {
  if (navigator.vibrate) navigator.vibrate(ms);
}
