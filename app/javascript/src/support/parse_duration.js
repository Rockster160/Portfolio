// One reading of a typed duration, shared by the prompt page and the form
// inside a Byte bubble so both agree on what "1:32" means.
//
// The same rules are implemented a second time, in Jil, by the `Parse Duration`
// function task — that is the one that decides what gets STORED, since a value
// can also arrive from Buddy or a tool call and never pass through a browser.
// This copy exists only to say, live and underneath the box, what the other one
// is going to do with it. Keep them in step.
//
//   ""        -> null      (blank stays blank; never 0)
//   "52"      -> 52
//   "1:32"    -> 92        H:MM
//   "1:04:35" -> 65        H:MM:SS, to the nearest minute
//   "97m"     -> 97
//   "1h 32"   -> 92        a trailing bare number is minutes
//   "11h24m"  -> 684
//
// A bare number at the END is minutes. It has to be anchored there, or "1 hour
// 32" reads its own "1" a second time and comes out 93.
const COLON_RX = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/;
const HOURS_RX = /(\d+(?:\.\d+)?)\s*(?:hours|hour|hrs|hr|h)(?![a-z])/i;
const MINS_RX = /(\d+(?:\.\d+)?)\s*(?:minutes|minute|mins|min|m)(?![a-z])/i;
const SECS_RX = /(\d+(?:\.\d+)?)\s*(?:seconds|second|secs|sec|s)(?![a-z])/i;
const TAIL_RX = /(\d+(?:\.\d+)?)\s*$/;

export function parseDurationMinutes(raw) {
  const text = String(raw ?? "").trim().replace(/\s+/g, " ");
  // No digit anywhere means nothing was typed, or nothing that could be read.
  // Either way there is no number to report, and 0 would be a lie.
  if (!/\d/.test(text)) return null;

  const colon = text.match(COLON_RX);
  if (colon) {
    const [, h, m, s] = colon;
    return Math.round(Number(h) * 60 + Number(m) + Number(s || 0) / 60);
  }

  const hours = text.match(HOURS_RX);
  const mins = text.match(MINS_RX);
  const secs = text.match(SECS_RX);
  const tail = text.match(TAIL_RX);

  const total =
    (hours ? Number(hours[1]) * 60 : 0) +
    (mins ? Number(mins[1]) : 0) +
    (secs ? Number(secs[1]) / 60 : 0) +
    (tail ? Number(tail[1]) : 0);

  return Math.round(total);
}

// The subtext under the box. Says the clock form AND the minutes, because the
// minutes are what gets stored and the clock form is what was meant.
export function formatDurationHint(minutes) {
  if (minutes == null) return "";
  if (minutes === 0) return "0 minutes";
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? "" : "s"}`;

  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  const clock = m ? `${h}h ${m}m` : `${h}h`;
  return `${clock} · ${minutes} minutes`;
}
