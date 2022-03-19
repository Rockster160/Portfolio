$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  var renderEvents = function(cell, events) {
    cell.lines(events.map(function(item) {
      if (cell.data.quiet && item.event_name.length == 1) { return }

      var timestamp = Time.at(Date.parse(item.timestamp))
      var h = timestamp.getHours()
      var time = (h > 12 ? h - 12 : h) + ":" + String(timestamp.getMinutes()).padStart(2, "0")
      var notes = item.notes ? " (" + item.notes + ")" : ""

      return Text.justify(item.event_name + notes, time || "")
    }).filter(function(line) { return line && line.length > 0 }))
  }

  Cell.init({
    title: "Recent",
    text: "Loading...",
    x: 2,
    y: 1,
    commands: {
      quiet: function() {
        this.data.quiet = !this.data.quiet
        this.reload()
      },
    },
    socket: Server.socket("RecentEventsChannel", function(msg) {
      if (!msg.recent_events) { return }

      renderEvents(this, msg.recent_events)
    }),
    reloader: function() {
      var cell = this
      $.getJSON("/action_events", function(data) {
        renderEvents(cell, data)
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + JSON.stringify(data))
      })
    },
    command: function(text) {
      if (/\d+/.test(text)) {
        Server.post("/functions/pullups_counter/run", { count: text })
      } else {
        var [name, ...notes] = text.split(" ")
        name = name.charAt(0).toUpperCase() + name.slice(1).toLowerCase()
        notes = notes.join(" ")
        Server.post("/action_events", { event_name: name, notes: notes })
      }
    },
  })
})
