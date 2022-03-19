$(".ctr-dashboard").ready(function() {
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
        var [name, ...notes] = text.split(" ")
        name = name.charAt(0).toUpperCase() + name.slice(1).toLowerCase()
        notes = notes.join(" ")
        Server.post("/action_events", { event_name: name, notes: notes })
      }
    },
  })
})
