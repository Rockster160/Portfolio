import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors } from "../vars"

(function() {
  let cell = undefined

  function dateLine(date) {
    return Text.center(` ${date.toDateString().replace(" 0", " ").replace(/ \d{4}/, "")} `, null, "-")
  }

  function timeFromDate(date) {
    let hours = date.getHours()
    const minutes = String(date.getMinutes()).padStart(2, "0")
    const period = hours >= 12 ? "pm" : "am"
    hours = (hours % 12) || 12
    return `${hours}:${minutes}${period}`
  }

  const formatTime = (date, options) => {
    return new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "numeric",
      hour12: true,
      ...options
    }).format(date).replace(" ", "").toLowerCase()
  }

  function timezonesLine() {
    const date = new Date()

    const mdtTime = "M-" + formatTime(date, { timeZone: "America/Denver" })
    const utcTime = "UTC-" + formatTime(date, { timeZone: "UTC", hour12: false })
    const azTime = "I-" + formatTime(date, { timeZone: "CST" })
    return Text.justify(mdtTime, utcTime, azTime)
  }

  function renderLines() {
    let lines = [timezonesLine()]
    if (!cell.data.events) { return cell.lines(lines) }

    let lastDateLine = dateLine(new Date())
    lines.push(lastDateLine)
    cell.data.events.forEach(event => {
      const { uid, name, unix, notes, location, calendar, start_time, end_time } = event
      const time = new Date(start_time)
      const eventDateLine = dateLine(time)

      if (lastDateLine !== eventDateLine) {
        lastDateLine = eventDateLine
        lines.push("")
        lines.push(lastDateLine)
      }

      let color = "lblue"
      if (calendar == "rocco@oneclaimsolution.com") { color = "green" }
      if (calendar == "Workout") { color = "orange" }
      const nameLine = Text.color(dash_colors[color], `• ${name} `)

      let timeStr = ""
      timeStr = timeFromDate(time)
      if (end_time) {
        const endTime = new Date(end_time)
        timeStr = `${timeStr}-${timeFromDate(endTime)}`
      }
      timeStr = Text.yellow(timeStr)

      lines.push(nameLine)
      lines.push("    " + timeStr)
      // lines.push(Text.justify(nameLine, timeStr))

      if (location && !location.match(/zoom\.us|meet\.google|webinar/i)) {
        lines.push("    " + Text.grey(location.replace("\n", " ")))
      }
    })
    cell.lines(lines)
  }

  const ticker = () => setTimeout(() => ticker() && renderLines(), Time.msUntilNextMinute()+1)
  ticker()

  cell = Cell.register({
    title: "Calendar",
    text: "Loading...",
    data: { events: [] },
    wrap: true,
    flash: false,
    onload: function() {
      cell.monitor = Monitor.subscribe("calendar", {
        connected: function() {
          cell.monitor?.resync()
        },
        disconnected: function() {},
        received: function(json) {
          if (json.data.events) {
            cell.flash()
            cell.data.events = json.data.events
            renderLines()
          } else {
            console.log("Unknown data for Monitor.events:", json)
          }
        },
      })
    },
  })
})()

// CALENDAR_COLORS = {
//   grey:     "#42464A",
//   yellow:   "#CBCB4D",
//   paleblue: "#9FE1E7",
//   lblue:    "#3D94F6",
//   magenta:  "#B55088",
//   pink:     "#EE9BB5",
//   green:    "#65DB39",
//   pine:     "#3E8948",
//   orange:   "#FF9500",
//   brown:    "#A2845D",
//   red:      "#FF0000",
// }

// today_str = Time.current.in_time_zone("Mountain Time (US & Canada)").strftime("%b %-d, %Y:")
// # calendar_data = LocalDataCalendarParser.call
//
// mapped_colors = {
//   "rocco11nicholls@gmail.com"   => :lblue,
//   "rocco.nicholls@workwave.com" => :orange,
//   "rocco@oneclaimsolution.com"  => :pine,
//   "Workout"                     => :brown,
// }
//
// calendar_data.map { |date_str, events|
//   lines = [date_str, "[hr]"]
//   events.sort_by { |evt| evt[:start_time] || Time.current.beginning_of_day }.each do |event|
//     next if event[:name].in?(ignore_list)
//     if event[:time_str].present?
//       name = event[:name] || event[:uid]
//       color = mapped_colors[event[:calendar]]
//       name = colorize(name, color) if color.present?
//       lines.push("• #{name}")
//       lines.push("    #{colorize(event[:time_str], :yellow)}")
//     else
//       lines.push("• #{colorize(event[:name] || event[:uid], :magenta)}")
//     end
//     next if event[:location].blank?
//     next if event[:location].include?("zoom.us")
//     next if event[:location].include?("meet.google")
//     next if event[:location].match?(/webinar/i) # GoToWebinar
//
//     lines.push("    #{colorize(event[:location].strip, :grey)}")
//   end
//   lines.push("") # Empty line between days
// }.flatten
// end
