// Shared duration helpers. Parsing accepts:
//   • bare integer    "30"      → 30 seconds
//   • single unit     "5m"      → 5 minutes
//   • decimal unit    "4.5m"    → 4 min 30 sec
//   • mixed unit      "1h30m"   → 90 minutes
//   • colon time      "4:30"    → 4 min 30 sec
//   • hh:mm:ss        "1:30:00" → 1 hour 30 min
// `humanizeSeconds` produces the live-preview text shown next to the
// duration input — phrase-form so it doubles as a parse validator.

export function parseDuration(input) {
  if (input == null) return null;
  const s = String(input).trim().toLowerCase();
  if (s === "") return null;

  if (s.includes(":")) {
    const parts = s.split(":").map((p) => p.trim());
    if (!parts.every((p) => /^\d+$/.test(p))) return null;
    const nums = parts.map((p) => parseInt(p, 10));
    if (nums.length === 2) return nums[0] * 60 + nums[1];        // mm:ss
    if (nums.length === 3) return nums[0] * 3600 + nums[1] * 60 + nums[2]; // hh:mm:ss
    return null;
  }

  if (/^\d+$/.test(s)) return parseInt(s, 10); // bare = seconds

  // Reject anything that's not unit-form. Allow optional space between
  // chunks (`1h 30m`), reject orphan tokens like `30 mins` or `m30`.
  // Decimal values per chunk are allowed (e.g. `4.5m` = 4m30s).
  if (!/^(\d+(?:\.\d+)?\s*[hms]\s*)+$/.test(s)) return null;

  let total = 0;
  s.replace(/(\d+(?:\.\d+)?)\s*([hms])/g, (_, n, unit) => {
    const v = parseFloat(n);
    if (unit === "h") total += v * 3600;
    if (unit === "m") total += v * 60;
    if (unit === "s") total += v;
    return "";
  });
  total = Math.round(total);
  return total > 0 ? total : null;
}

export function formatDurationShort(seconds) {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600 && s % 60 === 0) return `${s / 60}m`;
  if (s < 3600) return `${Math.floor(s / 60)}m${s % 60}s`;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return m ? `${h}h${m}m` : `${h}h`;
}

// "0:00", "30", "12:34" ring display. Drops to mm:ss under an hour.
export function formatRingTime(ms) {
  if (ms <= 0) return "0:00";
  const total = Math.ceil(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}

// "+0:05", "+1:23" elapsed-since-fire display for timers that require
// confirmation. Signed so the UI can show how long ago it went off.
export function formatElapsedTime(ms) {
  const total = Math.floor(Math.max(0, ms) / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `+${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `+${m}:${String(s).padStart(2, "0")}`;
}

export function defaultLabelForSeconds(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds % 60 === 0) return `${seconds / 60}m`;
  return formatDurationShort(seconds);
}

export function humanizeSeconds(s) {
  if (s == null || !Number.isFinite(s)) return null;
  if (s <= 0) return "0 seconds";
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const parts = [];
  if (h > 0)   parts.push(h   === 1 ? "1 hour"   : `${h} hours`);
  if (m > 0)   parts.push(m   === 1 ? "1 minute" : `${m} minutes`);
  if (sec > 0) parts.push(sec === 1 ? "1 second" : `${sec} seconds`);
  return parts.join(", ");
}
