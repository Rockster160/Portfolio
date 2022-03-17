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
        var name = text.charAt(0).toUpperCase() + text.slice(1).toLowerCase()
        Server.post("/action_events", { event_name: name })
      }
    },
  })
})
