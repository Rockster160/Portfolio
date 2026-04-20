import { Text } from "../_text";
import { Time } from "./_time";
import { dash_colors, clamp } from "../vars";

let contrastText = function (hex, text) {
  // Parse hex to RGB and compute relative luminance
  let c = hex.replace("#", "");
  if (c.length === 3) c = c[0] + c[0] + c[1] + c[1] + c[2] + c[2];
  let r = parseInt(c.substring(0, 2), 16) / 255;
  let g = parseInt(c.substring(2, 4), 16) / 255;
  let b = parseInt(c.substring(4, 6), 16) / 255;
  let lum = 0.299 * r + 0.587 * g + 0.114 * b;
  let fg = lum > 0.5 ? "#000000" : "#FFFFFF";
  return Text.bgColor(hex, Text.color(fg, ` ${text} `));
};

(function () {
  let cell = {};
  const CELL_LINES = 9;

  class Printer {
    static post(command, args) {
      return $.ajax({
        url: "/printer_control",
        data: { command: command, args: args },
        dataType: "json",
        type: "POST",
      });
    }
  }

  let timestampToDuration = function (seconds) {
    if (!seconds || seconds <= 0) {
      return "0s";
    }
    let h = Math.floor(seconds / 3600);
    let m = Math.floor((seconds % 3600) / 60);
    let s = Math.floor(seconds % 60);
    let parts = [];
    if (h > 0) {
      parts.push(`${h}h`);
    }
    if (m > 0) {
      parts.push(`${m}m`);
    }
    if (s > 0 || parts.length == 0) {
      parts.push(`${s}s`);
    }
    return parts.join("");
  };

  let tempsLine = function () {
    let temps = (cell.data.monitor_data || {}).temps;
    if (!temps || !temps.updated_at) {
      return null;
    }

    let updatedMs = new Date(temps.updated_at).getTime();
    if (Date.now() - updatedMs > Time.hours(1)) {
      return null;
    }

    let nozzle = Emoji.pen + Math.round(temps.nozzle || 0) + "°";
    let bed = Emoji.printer + " " + Math.round(temps.bed || 0) + "°";
    if (
      temps.nozzle_target > 0 &&
      temps.nozzle_target > (temps.nozzle || 0) + 0.5
    ) {
      nozzle += " (" + Math.round(temps.nozzle_target) + ")";
    }
    if (temps.bed_target > 0 && temps.bed_target > (temps.bed || 0) + 0.5) {
      bed += " (" + Math.round(temps.bed_target) + ")";
    }
    return Text.center(nozzle + " | " + bed);
  };

  let timeagoLine = function () {
    let data = cell.data.monitor_data || {};
    let lastUpdated = data.last_updated;
    if (!lastUpdated) {
      return "";
    }
    return Text.grey(
      Text.justify("", Time.timeago(new Date(lastUpdated).getTime())),
    );
  };

  let padLines = function (lines) {
    // Pad to CELL_LINES so timestamp is always at the bottom
    while (lines.length < CELL_LINES) {
      lines.splice(lines.length - 1, 0, "");
    }
    return lines;
  };

  var renderLines = function () {
    if (!cell) {
      return;
    }
    let data = cell.data.monitor_data || {};
    let status = data.status;
    let lines = [];

    // Line 1: Temps
    lines.push(
      tempsLine() || Text.center(Emoji.pen + "?° | " + Emoji.printer + " ?°"),
    );

    if (!status || status == "idle") {
      lines.push(Text.center("???"));
      lines.push(timeagoLine());
      cell.lines(padLines(lines));
      return;
    }

    // Line 2: Status (grey/muted)
    lines.push(Text.center(Text.grey(status || "Unknown")));

    // Line 3: Print name with filament color background
    let printLabel = data.print_name || "[Unknown]";
    if (data.filament_color) {
      printLabel = contrastText(data.filament_color, printLabel);
    }
    lines.push(Text.center(printLabel));

    // Line 4: Progress bar
    lines.push(Text.progressBar(data.progress || 0));

    // Line 5: Spacer | Result indicator (only for terminal states)
    let resultLabels = {
      complete: Text.green("[DONE]"),
      failed: Text.red("[FAIL]"),
      paused: Text.color(dash_colors.yellow, "[STOP]"),
    };
    lines.push(Text.center(resultLabels[status] || ""));

    let elapsed = Number(data.elapsed_sec) || 0;
    let estimated = Number(data.est_sec) || 0;
    let isDone = status == "complete" || status == "failed";
    let timeFmt = { hour: "numeric", minute: "2-digit" };

    // Line 6: Duration
    if (isDone) {
      let actualDuration = Number(data.actual_duration) || elapsed;
      lines.push(Text.center(timestampToDuration(actualDuration)));
    } else {
      lines.push(
        Text.center(
          timestampToDuration(elapsed) + " / " + timestampToDuration(estimated),
        ),
      );
    }

    // Line 7: Spacer
    lines.push("");

    // Line 8: ETA or completion time
    if (isDone) {
      let doneTime = data.last_updated ? new Date(data.last_updated) : null;
      lines.push(
        Text.center(
          doneTime ? "At: " + doneTime.toLocaleTimeString([], timeFmt) : "",
        ),
      );
    } else {
      let remaining = Math.max(estimated - elapsed, 0);
      if (remaining > 0) {
        let eta = new Date(Date.now() + remaining * 1000);
        lines.push(
          Text.center(
            "ETA: " +
              eta.toLocaleTimeString([], timeFmt) +
              " (" +
              timestampToDuration(remaining) +
              ")",
          ),
        );
      } else {
        lines.push(Text.center("ETA: --"));
      }
    }

    // Line 9 (last): timestamp -  padLines fills any gap
    lines.push(timeagoLine());

    cell.lines(padLines(lines));
  };

  cell = Cell.register({
    title: "Printer",
    text: "Loading...",
    data: {},
    refreshInterval: Time.minutes(1),
    reloader: function () {
      renderLines(); // Keeps the timeago line ticking
    },
    onload: function () {
      let monitor = Monitor.subscribe("printer", {
        connected: function () {
          monitor.resync();
        },
        received: function (msg) {
          if (msg.data) {
            let incoming = Number(msg.data.elapsed_sec) || 0;

            // Only reset the sync baseline if:
            // 1. We don't have one yet, OR
            // 2. The incoming value differs from our extrapolation by more than 5s
            //    (avoids resetting on stale resyncs/broadcasts)
            if (cell.data.sync_at == null) {
              cell.data.sync_at = Date.now();
              cell.data.sync_elapsed = incoming;
            } else {
              let extrapolated =
                cell.data.sync_elapsed +
                Math.floor((Date.now() - cell.data.sync_at) / 1000);
              if (Math.abs(incoming - extrapolated) > 5) {
                cell.data.sync_at = Date.now();
                cell.data.sync_elapsed = incoming;
              }
            }

            cell.data.monitor_data = msg.data;
            // Keep elapsed_sec in sync with our extrapolation, not the broadcast
            cell.data.monitor_data.elapsed_sec =
              cell.data.sync_elapsed +
              Math.floor((Date.now() - cell.data.sync_at) / 1000);
          }

          let status = (cell.data.monitor_data || {}).status;
          if (status == "printing") {
            if (!cell.data.interval_timer) {
              cell.data.interval_timer = setInterval(function () {
                let d = cell.data.monitor_data;
                if (!d) {
                  return;
                }
                let secsSinceSync = Math.floor(
                  (Date.now() - cell.data.sync_at) / 1000,
                );
                d.elapsed_sec = cell.data.sync_elapsed + secsSinceSync;
                d.remaining_sec = Math.max((d.est_sec || 0) - d.elapsed_sec, 0);
                d.progress =
                  d.est_sec > 0
                    ? Math.min((d.elapsed_sec / d.est_sec) * 100, 100)
                    : 0;
                renderLines();
              }, 1000);
            }
          } else {
            clearInterval(cell.data.interval_timer);
            cell.data.interval_timer = null;
          }

          renderLines();
          cell.flash();
        },
      });
    },
    command: function (words) {
      if (words.trim() == "o") {
        return window.open("http://zoro-pi-1.local/", "_blank");
      }
      let [cmd, ...args] = words.split(" ");
      Printer.post(cmd, args.join(" "));
    },
    commands: {
      gcode: function (cmd) {
        return Printer.post("command", cmd);
      },
      on: function () {
        return Printer.post("on");
      },
      off: function () {
        return Printer.post("off");
      },
      extrude: function (amount) {
        return Printer.post("extrude", amount);
      },
      retract: function (amount) {
        return Printer.post("retract", amount);
      },
      home: function () {
        return Printer.post("home");
      },
      move: function (amounts) {
        return Printer.post("move", amounts);
      },
      cool: function () {
        return Printer.post("cool");
      },
      pre: function () {
        return Printer.post("pre");
      },
    },
  });
})();
