// The label under a bubble: a clock, plus the date once the message isn't
// today's.
//
// A thread is scrollback. The time on its own is everything you need while it is
// still today's conversation and says nothing at all the moment somebody scrolls
// up past midnight - "9:42 AM" on a message from Tuesday reads as this morning.
// The right-click menu has carried a full timestamp all along for exactly this
// reason (see message_actions/context_menu.js), which is a thing you have to go
// looking for one message at a time.
//
// The shortest form that is still unambiguous at each distance, because this
// sits INSIDE the bubble: the meta row sets the bubble's minimum width, so a
// long label drags a one-word message out to the width of its own timestamp.
//
//   today          9:42 AM
//   yesterday      Yesterday · 9:42 AM
//   inside a week  Wed · 9:42 AM
//   this year      Sep 23 · 9:42 AM
//   older          Sep 23, 2025 · 9:42 AM
//
// A bare weekday is only unambiguous inside a week, which is why it stops there
// instead of being the general form.
//
// All five go through Intl with the viewer's own locale and timezone, the same
// as every other clock in the shell, so the day/month order is theirs.

const timeFmt = new Intl.DateTimeFormat(undefined, {
  hour: "numeric",
  minute: "2-digit",
});
const weekdayFmt = new Intl.DateTimeFormat(undefined, { weekday: "short" });
const dateFmt = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
});
const datedYearFmt = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  year: "numeric",
});

const DAY_MS = 86400000;
const SEPARATOR = " · ";

// Whole LOCAL calendar days between the two, never a 24-hour count. A count
// would call 11:30pm last night "today" until half past midnight and get every
// boundary wrong by the width of the current hour.
function daysApart(then, now) {
  const from = new Date(then.getFullYear(), then.getMonth(), then.getDate());
  const to = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return Math.round((to - from) / DAY_MS);
}

// The date half, or "" when the message is today's and the clock says it all.
export function messageDatePrefix(then, now) {
  const days = daysApart(then, now);
  // `<= 0` rather than `=== 0`: a stamp slightly in the future is a clock out of
  // step, not a message from tomorrow, and "Tomorrow · 9:42 AM" on something
  // that just arrived is worse than no date at all.
  if (days <= 0) return "";
  if (days === 1) return "Yesterday";
  if (days < 7) return weekdayFmt.format(then);
  if (then.getFullYear() === now.getFullYear()) return dateFmt.format(then);

  return datedYearFmt.format(then);
}

// `now` is injectable so a spec can stand somewhere; production passes nothing.
export function messageTimeLabel(iso, { now = new Date() } = {}) {
  if (!iso) return "";
  try {
    const then = new Date(iso);
    if (Number.isNaN(then.getTime())) return "";

    const clock = timeFmt.format(then);
    const prefix = messageDatePrefix(then, now);
    return prefix ? `${prefix}${SEPARATOR}${clock}` : clock;
  } catch {
    return "";
  }
}
