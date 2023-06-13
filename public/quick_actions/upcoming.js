import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { Time } from './time.js';

export let upcoming = new Widget("upcoming", function() {
  upcoming.loading = true
  upcoming.refresh()
})
upcoming.socket = new AuthWS("UpcomingEventsChannel", {
  onmessage: function(msg) {
    upcoming.loading = false
    upcoming.lines = msg.slice(0, 8).map(function(evt) {
      return parseTime(evt)
    })
    upcoming.last_sync = new Date()
  },
  onopen: function() {
    upcoming.connected()
    upcoming.refresh()
  },
  onclose: function() {
    upcoming.disconnected()
  }
})
upcoming.refresh = function() {
  upcoming.loading = true
  upcoming.socket.send({ action: "request" })
}
upcoming.refresh()

let parseTime = function(evt) {
  let timestamp = Date.parse(evt.timestamp)
  let d = Time.asData(timestamp)
  let date

  if (timestamp < Time.fromNow(Time.day())) { // if < 1 day
    // "10P"
    date = `${d.hour}${d.minute == 0 ? "" : ":" + String(d.minute).padStart(2, "0")}${d.mz[0]}`
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

  let name = evt.name?.replace(/^add /i, "") || "?"
  // return `${Text.color("#FEE761", date)}: ${Text.color("#0160FF", name)}`
  return `<span style="color: #FEE761;">${date}</span>: <span style="color: #0160FF;">${name}</span>`
  return `${date}: ${name}`
}
