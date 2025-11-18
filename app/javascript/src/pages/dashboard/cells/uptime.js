import { Text } from "../_text";
import { Time } from "./_time";
import { ColorGenerator } from "./color_generator";
import { dash_colors, scaleVal } from "../vars";

(function () {
  let cell;
  let cpu_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 5;
      scale[dash_colors.yellow] = 10;
      scale[dash_colors.red] = 20;
      return scale;
    })(),
  );
  let mem_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 50;
      scale[dash_colors.yellow] = 75;
      scale[dash_colors.red] = 80;
      return scale;
    })(),
  );
  let load_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 80;
      scale[dash_colors.yellow] = 150;
      scale[dash_colors.red] = 250;
      return scale;
    })(),
  );
  let latency_scale = ColorGenerator.colorScale(
    (function () {
      let scale = {};
      scale[dash_colors.green] = 10;
      scale[dash_colors.yellow] = 60;
      scale[dash_colors.red] = 100;
      return scale;
    })(),
  );

  var uptimeData = function (cell, flash = false) {
    var api_key = cell.config.uptime_apikey;
    var url = "https://api.uptimerobot.com/v2/getMonitors";
    $.post(
      url,
      { api_key: api_key, custom_uptime_ratios: "7" },
      function (data) {
        let uptime_data = cell.data.uptime_data;
        data.monitors.forEach(function (monitor) {
          uptime_data[monitor.friendly_name] = {};
          uptime_data[monitor.friendly_name].status =
            {
              2: "ok",
              8: "hm",
              9: "bad",
            }[monitor.status] || "?";

          uptime_data[monitor.friendly_name].weekly = parseInt(
            monitor.custom_uptime_ratio.split(".")[0],
          );
        });
        renderCell(cell);
        if (flash) {
          cell.flash();
        }
      },
    ).fail(function (data) {
      cell.uptime_lines = ["Failed to retrieve:", JSON.stringify(data)];
      renderCell(cell);
    });
  };

  var uptimeLines = function (cell) {
    let mixed = {};
    let lines = [];
    for (let [name, data] of Object.entries(cell.data.uptime_data || {})) {
      mixed[name] = mixed[name] || {};
      mixed[name] = { ...mixed[name], ...data };
    }
    for (let [name, data] of Object.entries(cell.data.load_data || {})) {
      mixed[name] = mixed[name] || {};
      mixed[name] = { ...mixed[name], ...data };
    }

    let batteryScale = function (val, min, max) {
      let rounded = Math.round(scaleVal(val, min, max, 1, 8));
      let capped = [rounded, 1, 8].sort(function (a, b) {
        return a - b;
      })[1];
      switch (capped) {
        case 1:
          return "▁";
        case 2:
          return "▂";
        case 3:
          return "▃";
        case 4:
          return "▄";
        case 5:
          return "▅";
        case 6:
          return "▆";
        case 7:
          return "▇";
        case 8:
          return "█";
      }
    };

    let formatScale = function (scale, text, b1, b2, b3) {
      let bs = [b1, b2, b3]
        .filter(function (b) {
          return b != undefined;
        })
        .map(function (b) {
          let battery = batteryScale(b, ...scale());

          return Text.color(scale(b).hex, battery);
        })
        .join("");

      return text + bs;
    };

    for (let [name, data] of Object.entries(mixed)) {
      let status_color =
        data.status == "ok" ? dash_colors.green : dash_colors.red;
      let colored_name = Text.color(status_color, "• " + name);
      let stats = [];
      let two_minutes_ago = new Date().getTime() / 1000 - 2 * 60 * 60;
      let cpu_icon = " ";
      let mem_icon = " ";
      let load_icon = " ";
      let latency_icon = "󰔛 ";

      if (data.latency && data.timestamp > two_minutes_ago) {
        stats.push(
          formatScale(latency_scale, latency_icon, data.latency.seconds),
        );
      } else {
        stats.push(latency_icon + Text.grey("?"));
      }
      if (data.cpu && data.timestamp > two_minutes_ago) {
        stats.push(formatScale(cpu_scale, cpu_icon, 100 - data.cpu.idle));
      } else {
        stats.push(cpu_icon + Text.grey("?"));
      }
      if (data.memory && data.timestamp > two_minutes_ago) {
        let ratio = Math.round((data.memory.used / data.memory.total) * 100);
        stats.push(formatScale(mem_scale, mem_icon, ratio));
      } else {
        stats.push(mem_icon + Text.grey("?"));
      }
      if (data.load && data.timestamp > two_minutes_ago) {
        stats.push(
          formatScale(
            load_scale,
            load_icon,
            data.load.one,
            data.load.five,
            data.load.ten,
          ),
        );
      } else {
        stats.push(load_icon + Text.grey("???"));
      }

      lines.push(Text.justify(colored_name, stats.join("  ")));
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
    let data = cell.data.mc_online_line;
    return [Text.center(cell.data.mc_online_line || "")];
  };

  var renderCell = function () {
    if (!cell) {
      return;
    }
    cell.lines([...uptimeLines(cell), ...mcOnline(cell), ...wsConns()]);
  };

  let tickTimer = undefined;

  cell = Cell.register({
    title: "Uptime",
    text: "Loading...",
    data: {
      uptime_data: {},
      ws_conns: [],
      load_data: {},
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
          cell.flash();
          if (data.loading) {
          } else {
            cell.data.ws_conns = data.data.connections;
            renderCell();
          }
        },
      });
      cell.mc_online_socket = Monitor.subscribe("mconline", {
        connected: function () {
          console.log("mconline Connected");
          setTimeout(function () {
            cell.mc_online_socket?.resync();
          }, 1000);
        },
        disconnected: function () {
          console.log("mconline Disconnected");
          renderCell();
        },
        received: function (data) {
          cell.flash();
          if (data.loading) {
          } else {
            // console.log(data);
            cell.data.mc_online_line = data.result;
            // console.log("line", cell.data.mc_online_line);
            renderCell();
          }
        },
      });
      clearInterval(tickTimer);
      tickTimer = setInterval(() => renderCell(cell), 1000);
    },
    // started: function() {
    // cell.uptime_socket.reopen()
    // },
    // stopped: function() {
    // cell.uptime_socket.close()
    // },
    // socket: Server.socket("LoadtimeChannel", function(msg) {
    //   this.data.load_data = msg
    //   renderCell(this)
    // }),
    refreshInterval: Time.minutes(10),
    reloader: function () {
      uptimeData(cell);
      cell.websockets_socket?.resync();
      // cell.ws.send("request")
    },
  });
})();
