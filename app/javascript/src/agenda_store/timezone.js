// Convert wall-clock (date + time) in an IANA timezone into a UTC epoch
// (seconds). Standard Date math always uses the host browser's zone, so
// for a user whose device timezone differs from their account timezone
// (travelling, server-set TZ, etc.) we need an explicit converter.
//
// The recurrence expander hands "2026-06-17" + "14:30" + "America/Denver"
// here, and the FE renderer pipes the result straight through the same
// epoch-second pipeline materialized AgendaItems use — no double zone
// translation downstream.
//
// Strategy: ask Intl.DateTimeFormat what the offset is FOR THAT WALL
// MOMENT in the target zone, then subtract it from the UTC interpretation
// of the wall time. Handles DST transitions correctly because we ask Intl
// to evaluate the same wall moment we're building.

function offsetMinutesAt(iso, hhmm, ianaTz) {
  const [Y, M, D] = String(iso).split("-").map(Number);
  const [h, m] = String(hhmm || "00:00").split(":").map(Number);
  // Treat the wall clock as if it were UTC, then ask Intl what wall time
  // that UTC instant maps to in ianaTz. The delta IS the offset.
  const asUtc = Date.UTC(Y, M - 1, D, h, m, 0);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: ianaTz,
    hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(asUtc));
  const map = {};
  parts.forEach((p) => { map[p.type] = p.value; });
  // Intl renders "24" instead of "00" for midnight in some locales.
  const hh = map.hour === "24" ? "00" : map.hour;
  const asZoneUtc = Date.UTC(
    Number(map.year), Number(map.month) - 1, Number(map.day),
    Number(hh), Number(map.minute), Number(map.second)
  );
  // ms the zone is AHEAD of UTC at this moment
  return (asZoneUtc - asUtc) / 60000;
}

// Wall-clock (dateISO, "HH:MM") in `ianaTz` → epoch seconds (UTC).
function localEpoch(dateISO, hhmm, ianaTz) {
  const [Y, M, D] = String(dateISO).split("-").map(Number);
  const [h, m] = String(hhmm || "00:00").split(":").map(Number);
  const naiveUtcMs = Date.UTC(Y, M - 1, D, h, m, 0);
  const offsetMin = offsetMinutesAt(dateISO, hhmm, ianaTz);
  return Math.floor((naiveUtcMs - offsetMin * 60000) / 1000);
}

// Convenience: bind a single timezone to produce a 2-arg fn for
// recurrence.buildPhantom.
function localEpochFn(ianaTz) {
  return (dateISO, hhmm) => localEpoch(dateISO, hhmm, ianaTz);
}

const AgendaTimezone = { localEpoch, localEpochFn, offsetMinutesAt };

if (typeof module !== "undefined" && module.exports) module.exports = AgendaTimezone;
if (typeof window !== "undefined") window.AgendaTimezone = AgendaTimezone;
