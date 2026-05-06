import { Text } from "../_text";
import { Time } from "./_time";
import { ColorGenerator } from "./color_generator";
import { dash_colors, scaleVal } from "../vars";

(function () {
  let cell;
  let cpu_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 50;
      scale[dash_colors.yellow] = 80;
      scale[dash_colors.red] = 100;
      return scale;
    })(),
  );
  let mem_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 70;
      scale[dash_colors.yellow] = 90;
      scale[dash_colors.red] = 100;
      return scale;
    })(),
  );
  let load_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 1;
      scale[dash_colors.yellow] = 2;
      scale[dash_colors.red] = 4;
      return scale;
    })(),
  );
  let disk_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 70;
      scale[dash_colors.yellow] = 85;
      scale[dash_colors.red] = 100;
      return scale;
    })(),
  );
  let latency_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 1;
      scale[dash_colors.yellow] = 10;
      scale[dash_colors.red] = 30;
      return scale;
    })(),
  );

  // A server's stats are considered "fresh" if it's reported within this window.
  let stale_after_seconds = 5 * 60;

  let col_width = 4;
  let formatStat = function (scale, value, formatter) {
    if (value == null || isNaN(value)) {
      return Text.grey("?".padStart(col_width));
    }
    let label = formatter(value).padStart(col_width);
    return Text.color(scale(value).hex, label);
  };

  let pct = (v) => `${Math.round(v)}%`;
  let secs = (v) => `${Math.round(v)}s`;
  let load_fmt = (v) => v.toFixed(2);

  let last_uptime_poll = 0;
  let uptime_poll_throttle_ms = 15 * 1000;

  var uptimeRobotPoll = function ({ force = false, flash = false } = {}) {
    let api_key = cell.config.uptime_apikey;
    if (!api_key) {
      return;
    }
    let now = Date.now();
    if (!force && now - last_uptime_poll < uptime_poll_throttle_ms) {
      return;
    }
    last_uptime_poll = now;
    $.post(
      "https://api.uptimerobot.com/v2/getMonitors",
      { api_key: api_key },
      function (data) {
        let next = {};
        (data.monitors || []).forEach(function (monitor) {
          next[monitor.friendly_name] = {
            status: { 2: "up", 8: "hm", 9: "down" }[monitor.status] || "?",
          };
        });
        cell.data.uptime_data = next;
        renderCell();
        if (flash) {
          cell.flash();
        }
      },
    ).fail(function (data) {
      cell.lines(["Failed to retrieve UptimeRobot:", JSON.stringify(data)]);
    });
  };

  var uptimeLines = function () {
    let lines = [];
    let now = new Date().getTime() / 1000;
    let uptime_data = cell.data.uptime_data || {};
    let servers = cell.data.servers || {};

    let header = Text.grey(
      ["lat", "cpu", "mem", "load", "disk"]
        .map((h) => h.padStart(col_width))
        .join(" "),
    );
    lines.push(Text.justify("", header));

    // Source of truth for which servers exist is UptimeRobot.
    // Server stats come from the Monitor broadcast — values render grey "?" when stale or absent.
    for (let [name, status_data] of Object.entries(uptime_data)) {
      let stats_data = servers[name] || {};
      let fresh =
        stats_data.timestamp &&
        now - stats_data.timestamp < stale_after_seconds;
      let up = status_data.status === "up";

      let dot_color = up
        ? fresh
          ? dash_colors.green
          : dash_colors.grey
        : dash_colors.red;
      let colored_name = Text.color(dot_color, "• " + name);

      let mem_pct =
        fresh && stats_data.memory_total_mb
          ? (stats_data.memory_used_mb / stats_data.memory_total_mb) * 100
          : null;

      let stats = (
        fresh
          ? [
              formatStat(latency_scale, stats_data.latency, secs),
              formatStat(cpu_scale, stats_data.cpu, pct),
              formatStat(mem_scale, mem_pct, pct),
              formatStat(load_scale, stats_data.load, load_fmt),
              formatStat(disk_scale, stats_data.disk, pct),
            ]
          : Array(5).fill(Text.grey("?".padStart(col_width)))
      ).join(" ");

      lines.push(Text.justify(colored_name, stats));
    }

    return lines;
  };

  var wsConns = function () {
    const ws_conns = cell.data.ws_conns;
    if (!ws_conns) {
      return [];
    }

    const now = Time.now().getTime();
    const labels = ws_conns.map((item) => {
      const timestamp = parseFloat(item.timestamp) * 1000;
      const duration = Time.durationFigs(now - timestamp)
        .split(" ")
        .map((s) => s.padStart(3))
        .join(" ");
      let time = duration;
      if (duration.length < 4 && !duration.match(/\ds/)) {
        time = `${time}  0s`;
      }
      time = Text.grey(time.padStart(7));
      const name = item.channel.padEnd(7);
      const label = item.connected ? Text.green(name) : Text.red(name);
      return `${label} ${time}`;
    });
    let lines = [];
    for (let i = 0; i < labels.length; i += 2) {
      lines.push(Text.justify(labels[i], labels[i + 1] || ""));
    }
    return lines;
  };

  var mcOnline = function () {
    return [Text.center(cell.data.mc_online_line || "")];
  };

  var renderCell = function () {
    if (!cell) {
      return;
    }
    cell.lines([...uptimeLines(), ...mcOnline(), ...wsConns()]);
  };

  let tickTimer = undefined;

  cell = Cell.register({
    title: "Uptime",
    text: "Loading...",
    data: {
      uptime_data: {},
      servers: {},
      ws_conns: [],
      mc_online_line: ". . . . .",
    },
    onload: function () {
      cell.websockets_socket = Monitor.subscribe("websockets", {
        connected: function () {
          setTimeout(function () {
            cell.websockets_socket?.resync();
          }, 1000);
        },
        disconnected: function () {
          renderCell();
        },
        received: function (data) {
          if (data.loading) {
            return;
          }
          cell.flash();
          cell.data.ws_conns = data.data.connections;
          renderCell();
        },
      });
      cell.uptime_socket = Monitor.subscribe("uptime", {
        connected: function () {
          setTimeout(function () {
            cell.uptime_socket?.resync();
          }, 1000);
        },
        disconnected: function () {
          renderCell();
        },
        received: function (data) {
          if (data.loading) {
            return;
          }
          cell.flash();
          if (data.data) {
            cell.data.servers = data.data;
          }
          uptimeRobotPoll({ flash: true });
          renderCell();
        },
      });
      cell.mc_online_socket = Monitor.subscribe("mconline", {
        connected: function () {
          setTimeout(function () {
            cell.mc_online_socket?.resync();
          }, 1000);
        },
        disconnected: function () {
          renderCell();
        },
        received: function (data) {
          if (data.loading) {
            return;
          }
          cell.flash();
          cell.data.mc_online_line = data.result;
          renderCell();
        },
      });
      uptimeRobotPoll({ force: true });
      clearInterval(tickTimer);
      tickTimer = setInterval(() => renderCell(), 1000);
    },
    refreshInterval: Time.minutes(10),
    reloader: function () {
      uptimeRobotPoll({ force: true });
      cell.uptime_socket?.refresh();
      cell.websockets_socket?.resync();
      cell.mc_online_socket?.resync();
    },
  });
})();
