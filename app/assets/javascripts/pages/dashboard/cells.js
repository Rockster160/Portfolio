$(".ctr-dashboard").ready(function() {
  var second = 1000, minute = second * 60, hour = minute * 60, day = hour * 24

  // var cell = Cell.init({
  //   title: "",
  //   text: "",
  //   interval: minute,
  //   reloader: function(cell) {},
  //   command: function(text, cell) {},
  // })

  var todo = Cell.init({
    title: "TODO",
    text: "Loading...",
    interval: minute,
    reloader: function(cell) {
      $.getJSON("/lists/todo", function(data) {
        cell.text(data.list_items.join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + data)
      })
    },
    command: function(text, cell) {
      $.ajax({
        url: "/lists/todo",
        type: "PATCH",
        dataType: "text",
        data: { message: text },
      }).done(function(data) {
        cell.reload()
      }).fail(function(data) {
        console.log("Failed to change TODO: ", data);
      })
    },
  })

  var grocery = Cell.init({
    title: "Grocery",
    text: "Loading...",
    interval: minute,
    reloader: function(cell) {
      $.getJSON("/lists/grocery", function(data) {
        cell.text(data.list_items.join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + data)
      })
    },
    command: function(text, cell) {
      $.ajax({
        url: "/lists/grocery",
        type: "PATCH",
        dataType: "text",
        data: { message: text },
      }).done(function(data) {
        cell.reload()
      }).fail(function(data) {
        console.log("Failed to change Grocery: ", data);
      })
    },
  })

  var uptime = Cell.init({
    title: "Uptime",
    text: "Loading...",
    interval: 5 * minute,
    reloader: function(cell) {
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
    },
  })

  var fitness = Cell.init({
    title: "Fitness",
    text: "Loading...",
    interval: 1 * hour,
    reloader: function(cell) {
      $.ajax({
        url: "/functions/fitness_data/run",
        type: "POST",
        dataType: "text",
        success: function(data) {
          if (!data) { return cell.text("!! Failed to retrieve !!") }
          console.log("json", data);
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
          cell.text(lines.join("\n"))
        },
        fail: function(data) {
          cell.text("!! Failed to retrieve: " + data)
        }
      })
    },
    command: function(text, cell) {
      if (/\d+/.test(text)) {
        $.ajax({
          url: "/functions/pullups_counter/run",
          data: { count: text },
          type: "POST",
          dataType: "text",
          success: function(data) {
            cell.reload()
          }
        })
      } else {
        var name = text.charAt(0).toUpperCase() + text.slice(1).toLowerCase()
        $.ajax({
          url: "/action_events",
          data: { event_name: name }, // event_name, notes, timestamp
          type: "POST",
          dataType: "text",
          success: function(data) {
            cell.reload()
          }
        })
      }
    },
  })

  var notes = Cell.init({
    title: "Notes",
    reloader: function() {},
    interval: 10 * second,
    command: function(text, cell) {
      cell.text([cell.text(), text].filter(function(words) { return words.length > 0 }).join("\n"))
    }
  })
})
