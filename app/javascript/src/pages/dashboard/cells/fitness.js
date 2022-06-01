(function() {
  Cell.register({
    title: "Fitness",
    text: "Loading...",
    socket: Server.socket("FitnessChannel", function(msg) {
      var lines = msg.fitness_data.split("\n")
      lines[0] = Text.center(lines[0])
      this.text(lines.join("\n"))
    }),
    refreshInterval: Time.msUntilNextDay() + Time.seconds(5),
    reloader: function() {
      this.refreshInterval = Time.msUntilNextDay() + Time.seconds(5)

      this.ws.send({ action: "request" })
    },
    command: function(text) {
      if (/^\d+/.test(text)) {
        Server.post("/functions/pullups_counter/run", { count: text })
      } else {
        var [name, ...notes] = text.split(" ")
        name = name.charAt(0).toUpperCase() + name.slice(1).toLowerCase()
        notes = notes.join(" ")
        Server.post("/action_events", { event_name: name, notes: notes })
      }
    },
  })
})()
