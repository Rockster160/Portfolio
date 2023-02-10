import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, text_height, clamp } from "../vars"

(function() {
  let cell = undefined

  let renderLines = function() {
    let lines = cell.data.lines
    cell.lines(lines)

    let content = cell.ele[0].querySelector(".dash-content")
    let max_lines = (content.scrollHeight - content.clientHeight)/text_height

    if (cell.livekey_active) {
      cell.data.scroll = clamp(cell.data.scroll, 0, max_lines)
    } else {
      cell.data.scroll = max_lines
    }

    content.scroll({ top: cell.data.scroll * text_height })
  }

  cell = Cell.register({
    title: "Upcoming",
    text: "Loading...",
    data: { lines: [] },
    refreshInterval: Time.hour(),
    reloader: function() {
      var cell = this

      cell.ws.send({ action: "request" })
    },
    socket: Server.socket("UpcomingEventsChannel", function(msg) {
      let lines = []
      console.log("Evt");
      msg.forEach(function(evt) {
        let timestamp = Date.parse(evt.timestamp)
        let d = Time.asData(timestamp)
        let date

        if (timestamp < Time.fromNow(Time.day())) { // if < 1 day
          // "10P"
          date = `${d.hour}${d.minute == 0 ? "" : String(d.minute).padStart(2, "0")}${d.mz[0]}`
        } else if (timestamp < Time.fromNow(Time.week())) { // if < 1 week
          // "T24 10M"
          let wday = Time.weekdays("single")[d.wday]
          date = `${wday}${d.date} ${d.hour}${d.minute == 0 ? "" : ":" + String(d.minute).padStart(2, "0")}${d.mz[0]}`
        } else { // if > week
          // "JanT24 10M"
          let mth = Time.monthnames("short")[d.month]
          let wday = Time.weekdays("single")[d.wday]
          date = `${mth}${wday}${d.date} ${String(d.hour).padStart(2, " ")}${d.minute == 0 ? "" : ":" + String(d.minute).padStart(2, "0")}${d.mz[0]}`
        }

        let line = `${Text.color(dash_colors.yellow, date)}: ${Text.color(dash_colors.rocco, evt.name)}`

        lines.push(line)
      })
      cell.data.lines = lines.slice(-100)
      renderLines()

      this.flash()
    }),
    onfocus: function() { renderLines() },
    onblur: function() { renderLines() },
    livekey: function(evt_key) {
      // Might need to reverse?
      this.data.scroll = this.data.scroll || 0

      evt_key = evt_key.toLowerCase()
      if (evt_key == "arrowup" || evt_key == "w") { this.data.scroll -= 1 }
      if (evt_key == "arrowdown" || evt_key == "s") { this.data.scroll += 1 }

      renderLines()
    }
  })
})()
