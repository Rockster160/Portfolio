import { Time } from "./_time"
import { Text } from "../_text"

(function() {
  Cell.register({
    title: "Fitness",
    text: "    💪 40t / 10.7d / 45.0m\n   Thu Wed Tue Mon Sun Sat Fri\n📖   ✓   ✓   ✓   ✓   ✓   ✓   ✓\n💊   ✓   ✓   ✓   ✓   ✓   ✓   ✓\n[img /can.png]   ✓   𐄂   ✓   ✓   ✓   ✓   ✓\n💧   1   𐄂   1   1   ✓   𐄂   ✓\n🤸   ✓   𐄂   𐄂   ✓   ✓   ✓   ✓\n🪥   ✓   ✓   𐄂   𐄂   ✓   𐄂   𐄂\n          🖊19° | 🖨 19° ",
    // socket: Server.socket("FitnessChannel", function(msg) {
    //   var lines = msg.fitness_data.split("\n")
    //   lines[0] = Text.center(lines[0])
    //   this.text(lines.join("\n"))
    // }),
    // refreshInterval: Time.msUntilNextDay() + Time.seconds(5),
    // reloader: function() {
    //   this.refreshInterval = Time.msUntilNextDay() + Time.seconds(5)
    //
    //   this.ws.send({ action: "request" })
    // },
    // command: function(text) {
    //   if (/^\d+/.test(text)) {
    //     Server.post("/functions/pullups_counter/run", { count: text })
    //   } else {
    //     var [name, ...notes] = text.split(" ")
    //     name = name.charAt(0).toUpperCase() + name.slice(1).toLowerCase()
    //     notes = notes.join(" ")
    //     Server.post("/action_events", { event_name: name, notes: notes })
    //   }
    // },
  })
})()
