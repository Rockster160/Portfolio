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

            return Text.justify(monitor.friendly_name, "(" + ratios.join("|") + ")")
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
          if (!data) {
            // Sometimes this will timeout due to other scripts all running at once
            // Retry after a short delay
            setTimeout(function() {
              cell.reload()
            }, 2000)

            return cell.text("!! Failed to retrieve !!")
          }
          var json = JSON.parse(data)
          var line_width = 27
          var lines = [
            Text.center("💪 " + json.pullups_today + " / " + json.pullups_today_goal + "  "),
            "",
            "   " + json.workouts.map(function(day) { return day[0] }).join(" "),
            "🤸 " + json.workouts.map(function(day) { return day[1] }).join(" "),
            "🥤 " + json.soda.map(function(day) { return day[1] }).join(" "),
            "🦷 " + json.teeth.map(function(day) { return day[1] }).join(" "),
            "🚿 " + json.shower.map(function(day) { return day[1] }).join(" "),
            "💊 " + json.vitamins.map(function(day) { return day[1] }).join(" "),
            // When adding text(), parse through and find all emojis and wrap them in a span
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
    x: 3,
    reloader: function(cell) {
      cell.text(localStorage.getItem("notes"))
    },
    command: function(text, cell) {
      if (text == ">clear") {
        localStorage.setItem("notes", "")
        return cell.text("")
      }

      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        lines.splice(num-1, 1)
      } else {
        var lines = (cell.text() || "").split("\n")
        lines.push(text)
        // A ticket to 大阪 costs ¥2000 👌. Repeated emojis: 😁😁. Crying cat: 😿. Repeated emoji with skin tones: ✊🏿✊🏿✊🏿✊✊✊🏿. Flags: 🇱🇹🏴󠁧󠁢󠁷󠁬󠁳󠁿. Scales ⚖️⚖️⚖️.
        // var lines = [cell.text(), text].filter(function(words) { return words && words.length > 0 }).join("")
        // new_note = new_note.split("\n").map(function(line) { return /^ - /.test(line) ? line : " - " + line }).join("\n")
      }

      var note = lines.map(function(line, idx) {
        console.log("line", idx, line);
        return (idx+1) + ". " + line.replace(/^\d+\. /, "")
      }).join("\n")

      localStorage.setItem("notes", note)
      cell.text(note)
    }
  })
})
