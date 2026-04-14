import { Text } from "../_text"
import { Time } from "./_time"
import { dash_colors, clamp } from "../vars"

(function() {
  let cell = {}

  class Printer {
    static post(command, args) {
      return $.ajax({
        url: "/printer_control",
        data: { command: command, args: args },
        dataType: "json",
        type: "POST",
      })
    }
  }

  let timestampToDuration = function(seconds) {
    if (!seconds || seconds <= 0) { return "0s" }
    let h = Math.floor(seconds / 3600)
    let m = Math.floor((seconds % 3600) / 60)
    let s = Math.floor(seconds % 60)
    let parts = []
    if (h > 0) { parts.push(`${h}h`) }
    if (m > 0) { parts.push(`${m}m`) }
    if (s > 0 || parts.length == 0) { parts.push(`${s}s`) }
    return parts.join("")
  }

  let tempsLine = function() {
    let temps = (cell.data.monitor_data || {}).temps
    if (!temps || !temps.updated_at) { return null }

    let updatedMs = new Date(temps.updated_at).getTime()
    let stale = (Date.now() - updatedMs) > Time.hours(1)
    if (stale) { return null }

    let nozzle = Emoji.pen + Math.round(temps.nozzle || 0) + "°"
    let bed = Emoji.printer + " " + Math.round(temps.bed || 0) + "°"
    if (temps.nozzle_target > 0 && temps.nozzle_target > (temps.nozzle || 0) + 0.5) {
      nozzle += " (" + Math.round(temps.nozzle_target) + ")"
    }
    if (temps.bed_target > 0 && temps.bed_target > (temps.bed || 0) + 0.5) {
      bed += " (" + Math.round(temps.bed_target) + ")"
    }
    return Text.center(nozzle + " | " + bed)
  }

  var renderLines = function() {
    if (!cell) { return }
    let data = cell.data.monitor_data || {}
    let status = data.status
    let lines = []

    // Temps line
    let temps = tempsLine()
    lines.push(temps || Text.center(Emoji.pen + "?° | " + Emoji.printer + " ?°"))
    lines.push("")

    if (!status || status == "idle") {
      lines.push(Text.center("Idle"))
      let lastUpdated = data.last_updated
      lines.push(Text.justify("", lastUpdated ? Time.timeago(new Date(lastUpdated).getTime()) : ""))
      cell.lines(lines)
      return
    }

    lines.push(Text.center(data.print_name || "[Unknown]"))

    if (status == "printing") {
      let progress = data.progress || 0
      lines.push(Text.progressBar(progress))
      lines.push("")

      let elapsed = data.elapsed_sec || 0
      let estimated = data.est_sec || 0
      let remaining = data.remaining_sec || 0

      lines.push(Text.center(timestampToDuration(elapsed) + " / " + timestampToDuration(estimated)))

      if (remaining > 0) {
        let eta = new Date(Date.now() + remaining * 1000)
        let etaStr = eta.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
        lines.push(Text.center("ETA: " + etaStr + " (" + timestampToDuration(remaining) + ")"))
      }
    } else if (status == "complete") {
      lines.push(Text.progressBar(100))
      lines.push("")
      lines.push(Text.center("Done in " + timestampToDuration(data.elapsed_sec)))
    } else if (status == "failed") {
      lines.push(Text.center(Text.red("[FAILED]")))
      if (data.error) {
        lines.push(Text.center(Text.grey(data.error)))
      }
      if (data.elapsed_sec) {
        lines.push(Text.center("After " + timestampToDuration(data.elapsed_sec)))
      }
    }

    let lastUpdated = data.last_updated
    lines.push(Text.justify("", lastUpdated ? Time.timeago(new Date(lastUpdated).getTime()) : ""))

    cell.lines(lines)
  }

  cell = Cell.register({
    title: "Printer",
    text: "Idle",
    data: {},
    onload: function() {
      let monitor = Monitor.subscribe("printer", {
        connected: function() {
          monitor.resync()
        },
        received: function(msg) {
          if (msg.data) { cell.data.monitor_data = msg.data }

          let status = (cell.data.monitor_data || {}).status
          if (status == "printing") {
            if (!cell.data.interval_timer) {
              cell.data.interval_timer = setInterval(function() {
                let d = cell.data.monitor_data
                if (d.remaining_sec > 0) { d.remaining_sec -= 1 }
                d.elapsed_sec = (d.elapsed_sec || 0) + 1
                renderLines()
              }, 1000)
            }
          } else {
            clearInterval(cell.data.interval_timer)
            cell.data.interval_timer = null
          }

          renderLines()
          cell.flash()
        },
      })
    },
    command: function(words) {
      if (words.trim() == "o") {
        return window.open("http://zoro-pi-1.local/", "_blank")
      }
      let [cmd, ...args] = words.split(" ")
      Printer.post(cmd, args.join(" "))
    },
    commands: {
      gcode: function(cmd) {
        return Printer.post("command", cmd)
      },
      on: function() {
        return Printer.post("on")
      },
      off: function() {
        return Printer.post("off")
      },
      extrude: function(amount) {
        return Printer.post("extrude", amount)
      },
      retract: function(amount) {
        return Printer.post("retract", amount)
      },
      home: function() {
        return Printer.post("home")
      },
      move: function(amounts) {
        return Printer.post("move", amounts)
      },
      cool: function() {
        return Printer.post("cool")
      },
      pre: function() {
        return Printer.post("pre")
      },
    },
  })
})()
