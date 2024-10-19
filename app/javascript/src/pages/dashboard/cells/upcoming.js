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
      cell.data.scroll = 0
    }

    content.scroll({ top: cell.data.scroll * text_height })
  }

  cell = Cell.register({
    title: "Upcoming",
    text: "\n\n\n" + Text.center(Text.red("== [FIXME] ==")),
    data: { lines: [] },
    refreshInterval: Time.hour(),
    reloader: function() {
      var cell = this
      cell.monitor?.send({ request: "get" })
    },
    onload: function() {
      cell.monitor = Monitor.subscribe("upcoming", {
        connected: function() {},
        disconnected: function() {},
        received: function(data) {
          if (data.data.lines) {
            cell.flash()
            cell.data.lines = data.data.lines
            renderLines()
          } else {
            console.log("Unknown data for Monitor.upcoming:", data)
          }
        },
      })
    },
    // TODO: Change this into a monitor.
    // socket: Server.socket("UpcomingEventsChannel", function(msg) {
    //   let lines = []
    //   msg.forEach(function(evt) {
    //     let timestamp = Date.parse(evt.timestamp)
    //     let d = Time.asData(timestamp)
    //     let date
    //
    //     if (timestamp < Time.fromNow(Time.day())) { // if < 1 day
    //       // "10P"
    //       date = `${d.hour}${d.minute == 0 ? "" : ":" + String(d.minute).padStart(2, "0")}${d.mz[0]}`
    //     } else if (timestamp < Time.fromNow(Time.week())) { // if < 1 week
    //       // "T24 10M"
    //       let wday = Time.weekdays("single")[d.wday]
    //       date = `${wday}${d.date} ${d.hour}${d.minute == 0 ? "" : ":" + String(d.minute).padStart(2, "0")}${d.mz[0]}`
    //     } else { // if > week
    //       // "JanT24 10M"
    //       let mth = Time.monthnames("short")[d.month]
    //       let wday = Time.weekdays("single")[d.wday]
    //       date = `${mth}${wday}${d.date} ${String(d.hour).padStart(2, " ")}${d.minute == 0 ? "" : ":" + String(d.minute).padStart(2, "0")}${d.mz[0]}`
    //     }
    //
    //     let name = evt.name?.replace(/^add /i, "") || "?"
    //     let line = `${Text.yellow(date)}: ${Text.rocco(name)}`
    //
    //     lines.push(line)
    //   })
    //   cell.data.lines = lines.slice(-100)
    //   renderLines()
    //
    //   this.flash()
    // }),
    onfocus: function() { renderLines() },
    onblur: function() { renderLines() },
    livekey: function(evt_key) {
      // Might need to reverse?
      this.data.scroll = this.data.scroll || 0

      evt_key = evt_key.toLowerCase()
      if (evt_key == "arrowup" || evt_key == "w") { this.data.scroll -= 1 }
      if (evt_key == "arrowdown" || evt_key == "s") { this.data.scroll += 1 }

      renderLines()
    },
    command: function(text) {
      // return window.open("https://ardesian.com/scheduled", "_blank")
    }
  })
})()
