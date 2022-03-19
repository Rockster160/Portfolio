$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  Cell.init({
    title: "Uptime",
    text: "Loading...",
    x: 4,
    y: 1,
    interval: Time.hour(),
    reloader: function(cell) {
      var api_key = authdata.uptime
      var url = "https://api.uptimerobot.com/v2/getMonitors"
      $.post(url, { api_key: api_key, custom_uptime_ratios: "7-30" }, function(data) {
        cell.text(
          data.monitors.map(function(monitor) {
            var color_map = {
              2: dash_colors.green,
              8: "orange",
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
          }).join("\n")
        )
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + JSON.stringify(data))
      })
    },
  })
})
