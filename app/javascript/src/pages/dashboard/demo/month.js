import { Time } from "../cells/_time"
import { Text } from "../_text"
import { dash_colors } from "../vars"

(function() {
  var startOfCalendarDate = function() {
    var date = Time.now()
    date.setDate(1)
    date.setDate(-date.getDay() + 1)
    date.setHours(0)
    date.setMinutes(0)
    date.setSeconds(0)

    return date
  }
  var endOfCalendarDate = function() {
    var date = Time.now()
    date.setDate(1)
    date.setMonth(date.getMonth() + 1)
    date.setDate(0)
    date.setDate(date.getDate() + (6 - date.getDay()))
    date.setHours(23)
    date.setMinutes(59)
    date.setSeconds(59)

    return date
  }
  var genMonth = function() {
    var day_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var now = Time.now()
    var month = now.getMonth()
    var date = now.getDate()

    var lines = []
    lines.push(Text.center(now.toLocaleString("en-us", { month: "long", year: "numeric" })))
    lines.push("")
    lines.push(Text.center(day_names.join(" ")))

    var calStart = startOfCalendarDate()
    var calEnd = endOfCalendarDate()
    var line = []
    while (calStart <= calEnd) {
      var color = "grey"
      var str = String(calStart.getDate()).padStart(3, " ")
      if (calStart.getMonth() == month) {
        color = "white"
        if ( calStart.getDate() == date) {
          color = "blue"
          str = Text.bgColor(dash_colors.bright, str)
        }
      }
      line.push(Text.color(color, str))

      if (calStart.getDay() == 6) {
        lines.push(Text.center(line.join(" ")))
        line = []
      }
      calStart.setDate(calStart.getDate() + 1)
    }
    return lines
  }


  Cell.register({
    title: "Month",
    refreshInterval: Time.msUntilNextDay() + Time.seconds(5),
    reloader: function() {
      this.refreshInterval = Time.msUntilNextDay() + Time.seconds(5)
      this.lines(genMonth())
    },
  })
})()
