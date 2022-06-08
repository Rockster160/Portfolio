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
    scale[dash_colors.green] = 80
    scale[dash_colors.yellow] = 150
    scale[dash_colors.red] = 250
    return scale
  })())

  var uptimeData = function(cell) {
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
    }).fail(function(data) {
      cell.uptime_lines = [
        "Failed to retrieve:",
        JSON.stringify(data),
      ]
      renderCell(cell)
    })
  }

  var rigData = function(cell) {
    // -- Currently broken because of CORS --
    // fetch(cell.data.base_url + "/farms", {
    //   method: "GET",
    //   headers: {
    //     "Authorization": "Bearer " + cell.config.hiveos_apikey,
    //     "Access-Control-Allow-Origin": "*"
    //   }
    // }).then(function(res) {
    //   res.json().then(function(json) {
    //     if (res.ok) {
    //       var lines = []
    //       json.data.forEach(function(rig) {
    //         lines.push(" " + rig.name)
    //         var online = "█ ".repeat(rig.stats.gpus_online)
    //         var offline = "█ ".repeat(rig.stats.gpus_total - rig.stats.gpus_online)
    //         lines.push(Text.center(Text.color(dash_colors.green, online) + Text.color(dash_colors.red, offline)))
    //       })
    //       cell.data.rig_lines = lines
    //     } else {
    //       cell.data.rig_lines = [
    //         "Error fetching farms:",
    //         JSON.stringify(json),
    //       ]
    //     }
    //     renderCell(cell)
    //   })
    // })
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

    let decorate = function(bgcolor, text) {
      let bold = Text.bold(text)
      let colored = Text.color("#112435", bold)
      let bg = Text.bgColor(bgcolor, colored)

      return bg
    }

    for (let [name, data] of Object.entries(mixed)) {
      let status_color = data.status == "ok" ? dash_colors.green : dash_colors.red
      let colored_name = Text.color(status_color, "• " + name)
      let stats = []
      let two_minutes_ago = ((new Date()).getTime() / 1000) - (2 * 60 * 60)
      if (data.memory && data.memory.timestamp > two_minutes_ago) {
        let ratio = Math.round((data.memory.used / data.memory.total) * 100)
        stats.push(decorate(mem_scale(ratio).hex, " M "))
      } else {
        stats.push(decorate(dash_colors.grey, " M "))
      }
      if (data.cpu && data.cpu.timestamp > two_minutes_ago) {
        stats.push(decorate(cpu_scale(data.cpu.idle).hex, " C "))
      } else {
        stats.push(decorate(dash_colors.grey, " C "))
      }
      if (data.load && data.load.timestamp > two_minutes_ago) {
        stats.push(decorate(load_scale(data.load.one).hex, " ◴1"))
        stats.push(decorate(load_scale(data.load.five).hex, " 5 "))
        stats.push(decorate(load_scale(data.load.ten).hex, " 10"))
      } else {
        stats.push(decorate(dash_colors.grey, " ◴1"))
        stats.push(decorate(dash_colors.grey, " 5 "))
        stats.push(decorate(dash_colors.grey, " 10"))
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
      load_data: {},

      base_url: "https://api2.hiveos.farm/api/v2",
    },
    socket: Server.socket("LoadtimeChannel", function(msg) {
      this.data.load_data = msg
      renderCell(this)
    }),
    refreshInterval: Time.minutes(10),
    reloader: function() {
      var cell = this
      uptimeData(cell)
      // rigData(cell)
      cell.ws.send("request")
    },
  })
})()
