import { Text } from "../_text"
import { Time } from "./_time"
import { ColorGenerator } from "./color_generator"
import { dash_colors } from "../vars"

(function() {
  let cell
  let cpu_scale = ColorGenerator.colorScale((function() {
    let scale = {}
    scale[dash_colors.green] = 5
    scale[dash_colors.yellow] = 10
    scale[dash_colors.red] = 20
    return scale
  })())
  let mem_scale = ColorGenerator.colorScale((function() {
    let scale = {}
    scale[dash_colors.green] = 50
    scale[dash_colors.yellow] = 75
    scale[dash_colors.red] = 80
    return scale
  })())
  let load_scale = ColorGenerator.colorScale((function() {
    let scale = {}
    scale[dash_colors.green] = 80
    scale[dash_colors.yellow] = 150
    scale[dash_colors.red] = 250
    return scale
  })())

  var uptimeData = function(cell, flash=false) {
    var api_key = cell.config.uptime_apikey
    var url = "https://api.uptimerobot.com/v2/getMonitors"
    $.post(url, { api_key: api_key, custom_uptime_ratios: "7" }, function(data) {
      let uptime_data = cell.data.uptime_data
      data.monitors.forEach(function(monitor) {
        uptime_data[monitor.friendly_name] = {}
        uptime_data[monitor.friendly_name].status = {
          2: "ok",
          8: "hm",
          9: "bad",
        }[monitor.status] || "?"

        uptime_data[monitor.friendly_name].weekly = parseInt(monitor.custom_uptime_ratio.split(".")[0])
      })
      renderCell(cell)
      if (flash) { cell.flash() }
    }).fail(function(data) {
      cell.uptime_lines = [
        "Failed to retrieve:",
        JSON.stringify(data),
      ]
      renderCell(cell)
    })
  }

  var uptimeLines = function(cell) {
    let mixed = {}
    let lines = []
    for (let [name, data] of Object.entries(cell.data.uptime_data || {})) {
      mixed[name] = mixed[name] || {}
      mixed[name] = { ...mixed[name], ...data }
    }
    for (let [name, data] of Object.entries(cell.data.load_data || {})) {
      mixed[name] = mixed[name] || {}
      mixed[name] = { ...mixed[name], ...data }
    }

    let scaleVal = function(value, f1, f2, t1, t2) {
      var tr = t2 - t1
      var fr = f2 - f1

      return (value - f1) * tr / fr + t1
    }

    let batteryScale = function(val, min, max) {
      let rounded = Math.round(scaleVal(val, min, max, 1, 8))
      let capped = [rounded, 1, 8].sort(function(a, b) { return a - b })[1]
      switch(capped) {
        case 1: return "▁"
        case 2: return "▂"
        case 3: return "▃"
        case 4: return "▄"
        case 5: return "▅"
        case 6: return "▆"
        case 7: return "▇"
        case 8: return "█"
      }
    }

    let formatScale = function(scale, text, b1, b2, b3) {
      let bs = [b1, b2, b3].filter(function(b) { return b != undefined }).map(function(b) {
        let battery = batteryScale(b, ...scale())

        return Text.color(scale(b).hex, battery)
      }).join("")

      return text + bs
    }

    for (let [name, data] of Object.entries(mixed)) {
      let status_color = data.status == "ok" ? dash_colors.green : dash_colors.red
      let colored_name = Text.color(status_color, "• " + name)
      let stats = []
      let two_minutes_ago = ((new Date()).getTime() / 1000) - (2 * 60 * 60)
      let cpu_icon = " "
      let mem_icon = " "
      let load_icon = " "

      if (data.cpu && data.timestamp > two_minutes_ago) {
        stats.push(formatScale(cpu_scale, cpu_icon, 100 - data.cpu.idle))
      } else {
        stats.push(cpu_icon + Text.color(dash_colors.grey, "?"))
      }
      if (data.memory && data.timestamp > two_minutes_ago) {
        let ratio = Math.round((data.memory.used / data.memory.total) * 100)
        stats.push(formatScale(mem_scale, mem_icon, ratio))
      } else {
        stats.push(mem_icon + Text.color(dash_colors.grey, "?"))
      }
      if (data.load && data.timestamp > two_minutes_ago) {
        stats.push(formatScale(load_scale, load_icon, data.load.one, data.load.five, data.load.ten))
      } else {
        stats.push(load_icon + Text.color(dash_colors.grey, "???"))
      }

      lines.push(Text.justify(colored_name, stats.join("  ")))
    }

    return lines
  }

  let subscribeWebsockets = function() {
    cell.uptime_socket = new CellWS(
      cell,
      Server.socket("UptimeChannel", function(msg) {
        uptimeData(cell, true)
      })
    )
  }

  var renderCell = function(cell) {
    cell.lines([
      ...uptimeLines(cell),
    ])
  }

  cell = Cell.register({
    title: "Uptime",
    text: "Loading...",
    data: {
      uptime_data: {},
      load_data: {},
    },
    onload: subscribeWebsockets,
    started: function() {
      cell.uptime_socket.reopen()
    },
    stopped: function() {
      cell.uptime_socket.close()
    },
    socket: Server.socket("LoadtimeChannel", function(msg) {
      this.data.load_data = msg
      renderCell(this)
    }),
    refreshInterval: Time.minutes(10),
    reloader: function() {
      uptimeData(cell)
      cell.ws.send("request")
    },
  })
})()
