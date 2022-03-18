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
      quiet: function(cell) {
        cell.data.quiet = !cell.data.quiet
        cell.reload()
      },
    },
    socket: Server.socket("RecentEventsChannel", function(cell, msg) {
      if (!msg.recent_events) { return }

      renderEvents(cell, msg.recent_events)
    }),
    reloader: function(cell) {
      $.getJSON("/action_events", function(data) {
        renderEvents(cell, data)
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + JSON.stringify(data))
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
})
