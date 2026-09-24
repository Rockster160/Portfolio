// Feeds timestamps through the real bubble label builder and prints the results
// as JSON for byte_message_time_spec.rb. No DOM - the label is pure, and `now`
// is handed in so the boundaries can be stood on rather than waited for.
import {
  messageTimeLabel,
  messageDatePrefix,
} from "../../app/javascript/src/pages/byte/message_time.js";

// A fixed Wednesday afternoon, in local time on purpose: the day boundaries are
// the viewer's calendar days, and a UTC instant would test a different thing.
const now = new Date(2026, 8, 23, 14, 30); // Wed 23 Sep 2026, 2:30pm
const at = (y, m, d, h, min) => new Date(y, m, d, h, min).toISOString();

const out = {};

out.today_morning = messageTimeLabel(at(2026, 8, 23, 9, 42), { now });
out.today_midnight = messageTimeLabel(at(2026, 8, 23, 0, 5), { now });
out.today_late = messageTimeLabel(at(2026, 8, 23, 23, 55), { now });

out.yesterday = messageTimeLabel(at(2026, 8, 22, 9, 42), { now });
// Twelve hours back but a day over the line: a 24-hour count would call this
// today until half past two.
out.yesterday_late = messageTimeLabel(at(2026, 8, 22, 23, 30), { now });

out.two_days = messageTimeLabel(at(2026, 8, 21, 9, 42), { now });
out.six_days = messageTimeLabel(at(2026, 8, 17, 9, 42), { now });
// Seven days back wears the same weekday name as today, so the weekday form has
// to have stopped by here.
out.seven_days = messageTimeLabel(at(2026, 8, 16, 9, 42), { now });

out.months_ago = messageTimeLabel(at(2026, 4, 3, 18, 5), { now });
out.last_year = messageTimeLabel(at(2025, 11, 24, 18, 5), { now });
// New Year's Eve is one day back and a different year - the yesterday form has
// to win, because it is still the more useful of the two.
out.new_years_eve = messageDatePrefix(
  new Date(2025, 11, 31, 22, 0),
  new Date(2026, 0, 1, 9, 0),
);

// A clock out of step, not a message from tomorrow.
out.future = messageTimeLabel(at(2026, 8, 24, 9, 0), { now });

out.blank = messageTimeLabel("", { now });
out.missing = messageTimeLabel(null, { now });
out.garbage = messageTimeLabel("not a date", { now });

process.stdout.write(JSON.stringify(out, null, 2));
