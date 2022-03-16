var demo = !true

$(".ctr-dashboard").ready(function() {
  Server = function() {}
  Server.request = function(url, type, data) {
    return $.ajax({
      url: url,
      data: data || {},
      dataType: "text",
      type: type || "GET",
    })
  }
  Server.post   = function(url, data) { return Server.request(url, "POST",  data) }
  Server.patch  = function(url, data) { return Server.request(url, "PATCH", data) }
  Server.get    = function(url, data) { return Server.request(url, "GET",   data) }
  Server.socket = function(subscription, receive) {
    var receive = receive
    var ws_protocol = location.protocol == "https:" ? "wss" : "ws", ws_open = false
    if (typeof subscription != "object") {
      subscription = { channel: subscription }
    }

    return {
      url: ws_protocol + "://" + location.host + "/cable",
      authentication: function(ws) {
        ws.send({ subscribe: subscription })
      },
      presend: function(packet) {
        if (typeof packet != "object" || !packet.subscribe) {
          packet = {
            command: "message",
            identifier: JSON.stringify(subscription),
            data: JSON.stringify(packet)
          }
        } else {
          packet = {
            command: "subscribe",
            identifier: JSON.stringify(packet.subscribe)
          }
        }

        return packet
      },
      receive: function(cell, msg) {
        var msg_data = JSON.parse(msg.data)
        if (msg_data.type == "ping" || !msg_data.message) { return }

        receive(cell, msg_data.message)
      }
    }
  }

  // var cell = Cell.init({
  //   title: "",
  //   text: "",
  //   commands: {},
  //   interval: Time.minute(),
  //   reloader: function(cell) {},
  //   command: function(text, cell) {},
  //   socket: {
  //     url: "",
  //     subscription: {
  //       channel: "",
  //       channel_id: "",
  //     },
  //     receive: function(cell, msg) {}
  //   },
  // })

  if (demo) { return }

  Cell.init({
    title: "Fitness",
    text: "Loading...",
    x: 1,
    y: 1,
    socket: Server.socket("FitnessChannel", function(cell, msg) {
      var lines = msg.fitness_data.split("\n")
      lines[0] = Text.center(lines[0])
      cell.text(lines.join("\n"))
    }),
    interval: Time.msUntilNextDay() + Time.seconds(5),
    reloader: function(cell) {
      cell.interval = Time.msUntilNextDay() + Time.seconds(5)

      cell.ws.send({ action: "request" })
    },
    command: function(text, cell) {
      if (/\d+/.test(text)) {
        Server.post("/functions/pullups_counter/run", { count: text })
      } else {
        var name = text.charAt(0).toUpperCase() + text.slice(1).toLowerCase()
        Server.post("/action_events", { event_name: name })
      }
    },
  })

  Cell.init({
    title: "TODO",
    text: "Loading...",
    x: 1,
    y: 4,
    socket: Server.socket({
      channel: "ListChannel",
      channel_id: "list_5",
    }, function(cell, msg) {
      if (!msg.list_data) { return }

      var lines = Text.numberedList(msg.list_data.list_items)
      cell.text(lines.join("\n"))
    }),
    reloader: function(cell) {
      $.getJSON("/lists/todo", function(data) {
        var lines = Text.numberedList(data.list_items)
        cell.text(lines.join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + JSON.stringify(data))
      })
    },
    command: function(text, cell) {
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        var item = lines[num-1]
        text = "remove " + item.replace(/^\d+\. /, "")
      }

      Server.patch("/lists/todo", { message: text })
        .fail(function(data) {
          console.log("Failed to change TODO: ", data);
        })
    },
  })

  Cell.init({
    title: "Grocery",
    text: "Loading...",
    x: 2,
    y: 4,
    socket: Server.socket({
      channel: "ListChannel",
      channel_id: "list_1",
    }, function(cell, msg) {
      if (!msg.list_data) { return }

      var lines = Text.numberedList(msg.list_data.list_items)
      cell.text(lines.join("\n"))
    }),
    reloader: function(cell) {
      $.getJSON("/lists/grocery", function(data) {
        var lines = Text.numberedList(data.list_items)
        cell.text(lines.join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + data)
      })
    },
    command: function(text, cell) {
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        var item = lines[num-1]
        text = "remove " + item.replace(/^\d+\. /, "")
      }

      Server.patch("/lists/grocery", { message: text })
        .fail(function(data) {
          console.log("Failed to change Grocery: ", data);
        })
    },
  })

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

  Cell.init({
    title: "Recent",
    text: "Loading...",
    x: 2,
    y: 1,
    socket: Server.socket("RecentEventsChannel", function(cell, msg) {
      if (!msg.recent_events) { return }

      cell.text(msg.recent_events.map(function(item) {
        var timestamp = Time.at(Date.parse(item.timestamp))
        var h = timestamp.getHours()
        var time = (h > 12 ? h - 12 : h) + ":" + String(timestamp.getMinutes()).padStart(2, "0")
        var notes = item.notes ? " (" + item.notes + ")" : ""
        return Text.justify(item.event_name + notes, time || "")
      }).join("\n"))
    }),
    reloader: function(cell) {
      $.getJSON("/action_events", function(data) {
        cell.text(data.map(function(item) {
          var timestamp = Time.at(Date.parse(item.timestamp))
          var h = timestamp.getHours()
          var time = (h > 12 ? h - 12 : h) + ":" + String(timestamp.getMinutes()).padStart(2, "0")
          var notes = item.notes ? " (" + item.notes + ")" : ""
          return Text.justify(item.event_name + notes, time || "")
        }).join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + data)
      })
    },
    command: function(text, cell) {
      var [name, ...notes] = text.split(" ")
      name = name.charAt(0).toUpperCase() + name.slice(1).toLowerCase()
      notes = notes.join(" ")
      $.ajax({
        url: "/action_events",
        data: { event_name: name, notes: notes }, // event_name, notes, timestamp
        type: "POST",
        dataType: "text"
      })
    },
  })

  Cell.init({
    title: "Notes",
    h: 2,
    w: 2,
    x: 1,
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

      var note = Text.numberedList(lines).join("\n")

      localStorage.setItem("notes", note)
      cell.text(note)
    }
  })
})
