$(".ctr-dashboard").ready(function() {
  if (demo) { return }

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
