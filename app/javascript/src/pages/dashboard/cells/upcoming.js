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
        let d = Time.asData(Date.parse(evt.timestamp))
        let mth = Time.monthnames("short")[d.month]
        let wday = Time.weekdays("single")[d.wday]

        let short = `${mth}${wday}${d.date} ${String(d.hour).padStart(2, " ")}:${String(d.minute).padStart(2, "0")}${d.mz}`
        let line = `${Text.color(dash_colors.yellow, short)}: ${Text.color(dash_colors.rocco, evt.name)}`
        // "JanT24 10:00AM"

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
