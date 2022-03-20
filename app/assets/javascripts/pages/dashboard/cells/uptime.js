$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  var uptimeData = function(cell) {
    var api_key = authdata.uptime
    var url = "https://api.uptimerobot.com/v2/getMonitors"
    $.post(url, { api_key: api_key, custom_uptime_ratios: "7-30" }, function(data) {
      cell.data.uptime_lines = data.monitors.map(function(monitor) {
        var color_map = {
          2: dash_colors.green,
          8: dash_colors.orange,
          9: dash_colors.red
        }
        var color = color_map[monitor.status] || dash_colors.yellow
        var colored_name = Text.color(color, "• " + monitor.friendly_name)

        var ratios = monitor.custom_uptime_ratio.split("-").map(function(num) {
          var percent = parseInt(num.split(".")[0])
          var color = dash_colors.yellow
          if (percent >= 99) { color = dash_colors.green }
          if (percent < 90) { color = dash_colors.red }

          return Text.color(color, percent + "%") }
        )

        return Text.justify(colored_name, "(" + ratios.join("|") + ")")
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
    fetch(cell.data.base_url + "/farms", {
      method: "GET",
      headers: { "Authorization": "Bearer " + cell.data.api_token }
    }).then(function(res) {
      res.json().then(function(json) {
        if (res.ok) {
          var lines = []
          lines.push("")
          json.data.forEach(function(rig) {
            if (rig.name == "Brendan Sr Murton") { return }
            lines.push(" " + rig.name)
            var online = "█ ".repeat(rig.stats.gpus_online)
            var offline = "█ ".repeat(rig.stats.gpus_total - rig.stats.gpus_online)
            lines.push(Text.center(Text.color(dash_colors.green, online) + Text.color(dash_colors.red, offline)))
            lines.push("")
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

  var renderCell = function(cell) {
    cell.lines([
      ...cell.data.uptime_lines,
      ...cell.data.rig_lines,
    ])
  }

  Cell.init({
    title: "Uptime",
    text: "Loading...",
    x: 3,
    y: 2,
    data: {
      uptime_lines: [],
      rig_lines: [],

      base_url: "https://api2.hiveos.farm/api/v2",
      api_token: authdata.hiveos,
    },
    interval: Time.minutes(10),
    reloader: function() {
      var cell = this
      uptimeData(cell)
      rigData(cell)
    },
  })
})
