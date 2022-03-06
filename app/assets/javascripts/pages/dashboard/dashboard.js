$(".ctr-dashboard").ready(function() {
  $(".dashboard").click(function() {
    $(".dashboard-omnibar input").focus()
  }).on("click", ".dash-cell", function() {
    var cell = Cell.from_ele(this)

    if (cell) {
      cell.active()
    }
  })
  $(document).on("keypress", ".dashboard-omnibar input", function(evt) {
    if (evt.which == keyEvent("ENTER")) {
      var cell = Cell.from_ele($(".dash-cell.active"))

      cell.execute($(this).val())
      var cmd = $(".dashboard-omnibar input").val()
      var selector = cmd.match(/\:(\w|\-)+ /i)
      $(".dashboard-omnibar input").val(selector[0])
    }
  })

  var second = 1000, minute = second * 60, hour = minute * 60, day = hour * 24

  var todo = (new Cell("TODO")).reloader(function(cell) {
    $.getJSON("/lists/todo", function(data) {
      cell.text(data.list_items.join("\n"))
    })
  }, 5 * minute)

  var grocery = (new Cell("Grocery")).reloader(function(cell) {
    $.getJSON("/lists/grocery", function(data) {
      cell.text(data.list_items.join("\n"))
    }).fail(function(data) {
      cell.text("Failed to retrieve: " + data)
    })
  }, 5 * minute).command(function(text) {
    $.post()
  })

  var uptime = (new Cell("Uptime")).reloader(function(cell) {
    var api_key = authdata.uptime
    var url = "https://api.uptimerobot.com/v2/getMonitors"
    $.post(url, { api_key: api_key, custom_uptime_ratios: "7-30" }, function(data) {
      cell.text(
        data.monitors.map(function(monitor) {
          var ratios = monitor.custom_uptime_ratio.split("-").map(function(num) { return num.split(".")[0] + "%" })
          return monitor.friendly_name + " (" + ratios.join("|") + ")"
        }).join("\n")
      )
    }).fail(function(data) {
      cell.text("Failed to retrieve: " + data)
    })
  }, 1 * hour)

  var fitness = (new Cell("Fitness")).reloader(function(cell) {
    var url = "/functions/fitness_data/run"
    $.ajax({
      url: url,
      type: "POST",
      dataType: "text",
      success: function(data) {
        if (!data) { cell.text("Failed to retrieve") }
        var json = JSON.parse(data)
        var lines = [
          "     " + json.pullups_today + " / " + json.pullups_today_goal,
          "",
          "   " + json.workouts.map(function(day) { return day[0] }).join(" "),
          "W: " + json.workouts.map(function(day) { return day[1] }).join(" "),
          "D: " + json.soda.map(function(day) { return day[1] }).join(" "),
          "T: " + json.teeth.map(function(day) { return day[1] }).join(" "),
          "S: " + json.shower.map(function(day) { return day[1] }).join(" "),
        ]
        cell.text(
          lines.join("\n")
        )
      },
      fail: function(data) {
        cell.text("Failed to retrieve: " + data)
      }
    })
  }, 1 * hour)
})
