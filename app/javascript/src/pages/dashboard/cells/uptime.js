import { Text } from "../_text"
import { Time } from "./_time"
import { ColorGenerator } from "./color_generator"
import { dash_colors } from "../vars"

(function() {
  let mem_scale = ColorGenerator.colorScale((function() {
    let scale = {}
    scale[dash_colors.green] = 50
    scale[dash_colors.yellow] = 75
    scale[dash_colors.red] = 80
    return scale
  })())
  let cpu_scale = ColorGenerator.colorScale((function() {
    let scale = {}
    scale[dash_colors.red] = 80
    scale[dash_colors.yellow] = 90
    scale[dash_colors.green] = 95
    return scale
  })())
  let load_scale = ColorGenerator.colorScale((function() {
    let scale = {}
    scale[dash_colors.green] = 8
    scale[dash_colors.yellow] = 15
    scale[dash_colors.red] = 25
    return scale
  })())

  var uptimeData = function(cell) {
    var api_key = cell.config.uptime_apikey
    var url = "https://api.uptimerobot.com/v2/getMonitors"
    $.post(url, { api_key: api_key, custom_uptime_ratios: "7" }, function(data) {
      let uptime_data = cell.data.uptime_data
      data.monitors.forEach(function(monitor) {
        // var color_map = {
        //   2: dash_colors.green,
        //   8: dash_colors.orange,
        //   9: dash_colors.red
        // }
        uptime_data[monitor.friendly_name] = {}
        uptime_data[monitor.friendly_name].status = {
          2: "ok",
          8: "hm",
          9: "bad",
        }[monitor.status] || "?"
        // var color = color_map[monitor.status] || dash_colors.yellow
        // var colored_name = Text.color(color, "• " + monitor.friendly_name)

        uptime_data[monitor.friendly_name].weekly = parseInt(monitor.custom_uptime_ratio.split(".")[0])
        // var ratios = monitor.custom_uptime_ratio.split("-").map(function(num) {
        //   var percent = parseInt(num.split(".")[0])
        //   var color = dash_colors.yellow
        //   if (percent >= 99) { color = dash_colors.green }
        //   if (percent < 90) { color = dash_colors.red }
        //
        //   return Text.color(color, percent + "%") }
        // )

        // return Text.justify(colored_name, "(" + ratios.join("|") + ")")
      })
      renderCell(cell)
    }).fail(function(data) {
      cell.uptime_lines = [
        "Failed to retrieve:",
        JSON.stringify(data),
      ]
      renderCell(cell)
    })
  }

  var rigData = function(cell) {
    return
    fetch(cell.data.base_url + "/farms", {
      method: "GET",
      headers: {
        "Authorization": "Bearer " + cell.config.hiveos_apikey,
        "Access-Control-Allow-Origin": "*"
      }
    }).then(function(res) {
      res.json().then(function(json) {
        if (res.ok) {
          var lines = []
          json.data.forEach(function(rig) {
            lines.push(" " + rig.name)
            var online = "█ ".repeat(rig.stats.gpus_online)
            var offline = "█ ".repeat(rig.stats.gpus_total - rig.stats.gpus_online)
            lines.push(Text.center(Text.color(dash_colors.green, online) + Text.color(dash_colors.red, offline)))
          })
          cell.data.rig_lines = lines
        } else {
          cell.data.rig_lines = [
            "Error fetching farms:",
            JSON.stringify(json),
          ]
        }
        renderCell(cell)
      })
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

    for (let [name, data] of Object.entries(mixed)) {
      let status_color = data.status == "ok" ? dash_colors.green : dash_colors.red
      let colored_name = Text.color(status_color, "• " + name)
      let stats = []
      if (data.memory) {
        let ratio = Math.round((data.memory.used / data.memory.total) * 100)
        stats.push(Text.bgColor(mem_scale(ratio).hex, Text.color("#112435", " M ")))
      }
      if (data.cpu) {
        stats.push(Text.bgColor(cpu_scale(data.cpu.idle).hex, Text.color("#112435", " C ")))
      }
      if (data.load) {
        stats.push(Text.bgColor(load_scale(data.load.one * 10).hex, Text.color("#112435", " ◴1")))
        stats.push(Text.bgColor(load_scale(data.load.five * 10).hex, Text.color("#112435", " 5 ")))
        stats.push(Text.bgColor(load_scale(data.load.ten * 10).hex, Text.color("#112435", " 10")))
      }

      lines.push(Text.justify(colored_name, stats.join(" ")))
    }

    return lines
  }

  var renderCell = function(cell) {
    cell.lines([
      ...uptimeLines(cell),
      ...cell.data.rig_lines,
    ])
  }

  Cell.register({
    title: "Uptime",
    text: "Loading...",
    data: {
      rig_lines: [],
      uptime_data: {},
      load_data: {
        "Portfolio": {
          memory: { used: Math.random() * 100, total: 100 },
          load: { one: Math.random()*2, five: Math.random()*2, ten: Math.random()*2 },
          cpu: { idle: 100 - Math.random()*3 }
        }
      },

      base_url: "https://api2.hiveos.farm/api/v2",
    },
    socket: Server.socket("LoadtimeChannel", function(msg) {
      cell.load_data = msg
      renderCell(this)
    }),
    receive: {},
    refreshInterval: Time.minutes(10),
    reloader: function() {
      var cell = this
      uptimeData(cell)
      // rigData(cell)
    },
  })
})()
