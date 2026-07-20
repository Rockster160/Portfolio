import { Time } from "../cells/_time"
import { Text } from "../_text"
import { dash_colors } from "../vars"

(function() {
  var DAY_MS = 24 * 60 * 60 * 1000

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

  var dateKey = function(d) {
    return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
  }

  // "4w" → 28, "7d" → 7, "1m" → 30 (approx). Returns days.
  var parseIntervalDays = function(str) {
    var m = String(str || "").trim().match(/^(\d+)\s*([dwm])?$/i)
    if (!m) { return 0 }
    var n = parseInt(m[1], 10)
    switch ((m[2] || "d").toLowerCase()) {
      case "w": return n * 7
      case "m": return n * 30
      default:  return n
    }
  }

  var resolveColor = function(name, fallback) {
    if (!name) { return fallback }
    return dash_colors[name] || name
  }

  // priority: due=2 (red) beats warn=1 (orange) when the same day carries both
  var upsertMarker = function(map, key, color, priority) {
    var existing = map[key]
    if (!existing || priority > existing.priority) {
      map[key] = { color: color, priority: priority }
    }
  }

  var markerByDate = {}

  var loadMarkers = function(cell) {
    var markers = (cell.config && cell.config.markers) || []
    if (!markers.length) {
      markerByDate = {}
      return $.Deferred().resolve().promise()
    }

    var queries = markers.map(function(m) { return m.query }).filter(Boolean)
    return Server.get("/action_events/latest", { queries: queries }).then(function(resp) {
      var data = typeof resp === "string" ? JSON.parse(resp) : resp
      var newMap = {}
      var end = endOfCalendarDate()
      var start = startOfCalendarDate()

      markers.forEach(function(m) {
        var lastIso = data[m.query]
        if (!lastIso) { return }

        var periodDays = parseIntervalDays(m.period)
        if (!periodDays) { return }

        var warnDays = parseIntervalDays(m.warn)
        var dueColor = resolveColor(m.color, dash_colors.red)
        var warnColor = resolveColor(m.warn_color, dash_colors.orange)

        var due = new Date(lastIso)
        due.setTime(due.getTime() + periodDays * DAY_MS)
        while (due <= end) {
          upsertMarker(newMap, dateKey(due), dueColor, 2)
          if (warnDays > 0) {
            var warn = new Date(due.getTime() - warnDays * DAY_MS)
            if (warn >= start) {
              upsertMarker(newMap, dateKey(warn), warnColor, 1)
            }
          }
          due.setTime(due.getTime() + periodDays * DAY_MS)
        }
      })

      markerByDate = newMap
    })
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
      var dayColor = "grey"
      var isToday = false
      if (calStart.getMonth() == month) {
        dayColor = "white"
        if (calStart.getDate() == date) {
          dayColor = "blue"
          isToday = true
        }
      }

      var raw = String(calStart.getDate()).padStart(3, " ")
      var marker = markerByDate[dateKey(calStart)]
      var cell
      if (marker) {
        cell = Text.color(marker.color, "•") + Text.color(dash_colors[dayColor], raw.slice(1))
      } else {
        cell = Text.color(dash_colors[dayColor], raw)
      }
      if (isToday) {
        cell = Text.bgColor(dash_colors.bright, cell)
      }
      line.push(cell)

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
      var cell = this
      cell.refreshInterval = Time.msUntilNextDay() + Time.seconds(5)
      cell.lines(genMonth())
      loadMarkers(cell).then(function() {
        cell.lines(genMonth())
      })
    },
  })
})()
