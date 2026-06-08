import { Time } from "./_time";
import { Text } from "../_text";
import { dash_colors } from "../vars";

(function () {
  let cell = undefined;

  function dateLine(date) {
    return Text.center(
      ` ${date
        .toDateString()
        .replace(" 0", " ")
        .replace(/ \d{4}/, "")} `,
      null,
      "-",
    );
  }

  function timeFromDate(date) {
    let hours = date.getHours();
    const minutes = String(date.getMinutes()).padStart(2, "0");
    const period = hours >= 12 ? "pm" : "am";
    hours = hours % 12 || 12;
    return `${hours}:${minutes}${period}`;
  }

  const formatTime = (date, options) => {
    return new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "numeric",
      hour12: true,
      ...options,
    })
      .format(date)
      .replace(" ", "")
      .toLowerCase();
  };

  function timezonesLine() {
    const date = new Date();

    // const mdtTime = "M-" + formatTime(date, { timeZone: "America/Denver" })
    const azTime = "A-" + formatTime(date, { timeZone: "US/Arizona" });
    const utcTime =
      "UTC-" + formatTime(date, { timeZone: "UTC", hour12: false });
    const iowaTime = "I-" + formatTime(date, { timeZone: "CST" });

    return Text.justify(azTime, utcTime, iowaTime);
  }

  function renderLines() {
    let lines = [timezonesLine()];
    if (!cell.data.events) {
      return cell.lines(lines);
    }

    const now = new Date();
    let lastDateLine = dateLine(now);
    lines.push(lastDateLine);
    cell.data.events.forEach((event) => {
      const {
        uid,
        name,
        unix,
        notes,
        location,
        calendar,
        start_time,
        end_time,
        all_day,
        kind,
      } = event;
      const isAllDay = all_day === "true" || all_day === true;
      const isTask = kind === "task";
      // start_time / end_time arrive as integer epoch seconds (UTC).
      // Display is always browser-local — the server never picks a zone.
      const time = isAllDay
        ? new Date((event.start_date || start_time) * 1000)
        : new Date(start_time * 1000);

      // Skip past events (re-evaluated each minute by ticker).
      // Tasks stay visible until completed — no end time to compare.
      if (!isAllDay && !isTask) {
        const endRef = end_time ? new Date(end_time * 1000) : time;
        if (endRef < now) {
          return;
        }
      }
      const eventDateLine = dateLine(time);

      if (lastDateLine !== eventDateLine) {
        lastDateLine = eventDateLine;
        lines.push("");
        lines.push(lastDateLine);
      }

      // Agenda events ship their own hex via `event.color` (display_color).
      // Fall back to a default palette color when no explicit hex is provided.
      const explicitHex =
        event.color && /^#[0-9A-F]{3,8}$/i.test(event.color)
          ? event.color
          : null;
      const resolvedColor = explicitHex || dash_colors["lblue"];

      if (isAllDay) {
        lines.push(
          Text.color(explicitHex || dash_colors["magenta"], `★ ${name}`),
        );
      } else {
        let timeStr = timeFromDate(time);
        if (end_time && !isTask) {
          const endTime = new Date(end_time * 1000);
          timeStr = `${timeStr}-${timeFromDate(endTime)}`;
        }
        timeStr = Text.yellow(timeStr);

        const nameLine = Text.color(resolvedColor, name);

        lines.push(nameLine);
        lines.push(timeStr);

        if (location && !location.match(/zoom\.us|meet\.google|webinar/i)) {
          const cleanLocation = location
            .replaceAll("\n", " ")
            .replaceAll(/\s{2,}/g, " ")
            .replace(
              /,?\s*UT\b(\s+\d{5}(-\d{4})?)?\s*,?\s*(?:USA|United States)?\s*$/i,
              "",
            )
            .replace(/,?\s*UT\b\s*$/i, "")
            .trim()
            .replace(/,\s*$/, "");
          lines.push(Text.grey(cleanLocation));
        }

        if (notes) {
          notes
            .split("\n")
            .map((line) => line.trim())
            .filter((line) => line.length > 0)
            .forEach((line) => lines.push(line));
        }
      }
    });
    cell.lines(lines);
  }

  const ticker = () =>
    setTimeout(() => ticker() && renderLines(), Time.msUntilNextMinute() + 1);
  ticker();

  cell = Cell.register({
    title: "Calendar",
    text: "Loading...",
    data: { events: [] },
    wrap: true,
    flash: false,
    onload: function () {
      cell.monitor = Monitor.subscribe("calendar", {
        connected: function () {
          cell.monitor?.resync();
        },
        disconnected: function () {},
        received: function (json) {
          if (json.data.events) {
            cell.flash();
            cell.data.events = json.data.events;
            renderLines();
          } else {
            console.log("Unknown data for Monitor.events:", json);
          }
        },
      });
    },
  });
})();
