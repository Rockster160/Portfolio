// doit = function() {
//
//
//
//     //Subscribe to the channel
//     var params = {
//       channel: "ListChannel",
//       channel_id: "list_5"
//     }
//     var msg = {
//       command: "subscribe",
//       identifier: JSON.stringify(params)
//     }
//     portfolio_ws.send(JSON.stringify(msg))
//
//     // const msg = {
//     //   command: 'message',
//     //   identifier: JSON.stringify({
//     //     channel: 'SomeChannel',
//     //   }),
//     //   data: JSON.stringify({
//     //     action: 'join',
//     //     code: 'NCC1701D',
//     //   }),
//     // };
//     // socket.send(JSON.stringify(msg));
//   }
//
//   portfolio_ws.onmessage = function(msg) {
//     var json = JSON.parse(msg.data)
//     // if (json.type == "ping") { return }
//
//     console.log(json);
//   }
// }

$(".ctr-dashboard").ready(function() {
  var second = 1000, minute = second * 60, hour = minute * 60, day = hour * 24
  var ws_protocol = location.protocol == "https:" ? "wss" : "ws", ws_open = false

  // var cell = Cell.init({
  //   title: "",
  //   text: "",
  //   interval: minute,
  //   reloader: function(cell) {},
  //   command: function(text, cell) {},
  // })

  var fitness = Cell.init({
    title: "Fitness",
    text: "Loading...",
    socket: {
      url: ws_protocol + "://" + location.host + "/cable",
      subscription: {
        channel: "FitnessChannel",
      },
      receive: function(cell, msg) {
        var lines = msg.fitness_data.split("\n")
        lines[0] = Text.center(lines[0])
        cell.text(lines.join("\n"))
      }
    },
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
          } else {
            var lines = data.split("\n")
            lines[0] = Text.center(lines[0])
            cell.text(lines.join("\n"))
          }
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

  var todo = Cell.init({
    title: "TODO",
    text: "Loading...",
    x: 4,
    y: 1,
    socket: {
      url: ws_protocol + "://" + location.host + "/cable",
      subscription: {
        channel: "ListChannel",
        channel_id: "list_5",
      },
      receive: function(cell, msg) {
        if (!msg.list_data) { return }

        cell.text(msg.list_data.list_items.join("\n"))
      }
    },
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
    x: 4,
    y: 2,
    text: "Loading...",
    socket: {
      url: ws_protocol + "://" + location.host + "/cable",
      subscription: {
        channel: "ListChannel",
        channel_id: "list_1",
      },
      receive: function(cell, msg) {
        if (!msg.list_data) { return }

        cell.text(msg.list_data.list_items.join("\n"))
      }
    },
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
            var color_map = {
              2: "green",
              8: "orange",
              9: "red"
            }
            var color = color_map[monitor.status] || "yellow"
            var colored_name = Text.color(color, "• " + monitor.friendly_name)

            var ratios = monitor.custom_uptime_ratio.split("-").map(function(num) {
              var percent = parseInt(num.split(".")[0])
              var color = "yellow"
              if (percent >= 99) { color = "green" }
              if (percent < 90) { color = "red" }

              return Text.color(color, percent + "%") }
            )

            return Text.justify(colored_name, "(" + ratios.join("|") + ")")
          }).join("\n")
        )
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + data)
      })
    },
  })

  var recent_events = Cell.init({
    title: "Recent",
    text: "Load once event comes in...",
    x: 3,
    y: 1,
    socket: {
      url: ws_protocol + "://" + location.host + "/cable",
      subscription: {
        channel: "RecentEventsChannel",
      },
      receive: function(cell, msg) {
        if (!msg.recent_events) { return }

        cell.text(msg.recent_events.join("\n"))
      }
    },
    reloader: function(cell) {
      // $.getJSON("/lists/todo", function(data) {
      //   cell.text(data.list_items.join("\n"))
      // }).fail(function(data) {
      //   cell.text("Failed to retrieve: " + data)
      // })
    },
    command: function(text, cell) {
      var [name, ...notes] = text.split(" ")
      name = name.charAt(0).toUpperCase() + name.slice(1).toLowerCase()
      notes = notes.join(" ")
      $.ajax({
        url: "/action_events",
        data: { event_name: name, notes: notes }, // event_name, notes, timestamp
        type: "POST",
        dataType: "text",
        success: function(data) {
          cell.reload()
        }
      })
    },
  })

  var notes = Cell.init({
    title: "Notes",
    h: 2,
    w: 2,
    y: 2,
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
        var lines = cell.text() ? cell.text().split("\n") : []
        lines.push(text)
        // A ticket to 大阪 costs ¥2000 👌. Repeated emojis: 😁😁. Crying cat: 😿. Repeated emoji with skin tones: ✊🏿✊🏿✊🏿✊✊✊🏿. Flags: 🇱🇹🏴󠁧󠁢󠁷󠁬󠁳󠁿. Scales ⚖️⚖️⚖️.
        // <div class="sup" style="color: red;"><color style="color: red;"><span>Hello!</span></color><e>✊🏿</e></div>
      }

      var note = lines.map(function(line, idx) {
        return (idx+1) + ". " + line.replace(/^\d+\. /, "")
      }).join("\n")

      localStorage.setItem("notes", note)
      cell.text(note)
    }
  })
})
