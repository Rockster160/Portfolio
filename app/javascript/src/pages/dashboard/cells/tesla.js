import { Text } from "../_text"
import { Time } from "./_time"
import { shiftTempToColor, dash_colors } from "../vars"

(function() {
  let cell = undefined

  let timeago = function(epoch_s) {
    if (!epoch_s) { return "" }
    let distance_seconds = ((new Date()).getTime() / 1000) - Math.abs(epoch_s)
    if (distance_seconds < 60) { return "just now" }

    let minutes = distance_seconds / 60
    if (minutes < 2) { return "1 minute ago" }
    if (minutes <= 120) { return Math.round(minutes) + " minutes ago" }

    let hours = minutes / 60
    if (hours < 2) { return "1 hour ago" }
    if (hours <= 50) { return Math.round(hours) + " hours ago" }

    let days = hours / 24
    if (days < 2) { return "1 day ago" }
    if (days <= 50) { return Math.round(days) + " days ago" }

    let weeks = days / 7
    if (weeks < 2) { return "1 week ago" }
    if (weeks <= 5) { return Math.round(weeks) + " weeks ago" }

    let months = weeks / 4
    if (months < 2) { return "1 month ago" }
    if (months <= 5) { return Math.round(months) + " months ago" }

    return "forever ago"
  }

  let renderLines = function() {
    let lines = [], data = cell.data.car
    lines.push(cell.data.loading ? "[ico ti ti-fa-spinner ti-spin]" : "")

    let status_pieces = []
    if (data.climate?.current) {
      status_pieces.push(shiftTempToColor(data.climate.current))
    }
    status_pieces.push(Text.color(dash_colors.yellow, (data.charge || "?") + "%"))
    status_pieces.push(Text.color(dash_colors.yellow, (data.miles || "?") + "m"))
    lines.push(Text.center(status_pieces.join(" | ")))

    if (data.charging?.active) {
      let charging_text = "Full: " + data.charging.eta + "min | [ico ti ti-weather-lightning]" + data.charging.speed + "mph"
      lines.push(Text.center(Text.color(dash_colors.yellow, charging_text)))
    } else {
      lines.push("")
    }

    lines.push("")
    if (data.open) {
      let opens = []
      if (data.open.ft > 0)        { opens.push("Frunk") }
      if (data.open.df > 0)        { opens.push("FDD") }
      if (data.open.fd_window > 0) { opens.push("FDW") }
      if (data.open.pf > 0)        { opens.push("FPD") }
      if (data.open.fp_window > 0) { opens.push("FPW") }
      if (data.open.dr > 0)        { opens.push("RDD") }
      if (data.open.rd_window > 0) { opens.push("RDR") }
      if (data.open.pr > 0)        { opens.push("RPD") }
      if (data.open.rp_window > 0) { opens.push("RPW") }
      if (data.open.rt > 0)        { opens.push("Trunk") }
      if (opens.length > 0) {
        lines.push(Text.center("Open: " + opens.join(",")))
      } else {
        lines.push("")
      }
    } else {
      lines.push("")
    }
    lines.push("")

    if (data.climate?.on) {
      let climate_text = "Climate: "
      climate_text += Text.color(dash_colors.green, "[ON] ")
      climate_text += shiftTempToColor(data.climate.set)
      lines.push(Text.center(climate_text))
    } else {
      lines.push(Text.center(Text.color(dash_colors.grey, "[OFF]")))
    }

    if (data.drive) {
      let drive_text = data.drive.action + ":" + data.drive.location
      if (data.drive.speed > 0) { drive_text += data.drive.speed + "mph" }
      lines.push(Text.center(Text.color(dash_colors.grey, drive_text)))
    } else {
      lines.push("")
    }

    lines.push(Text.justify("", timeago(data.timestamp)))

    cell.lines(lines)
  }

  cell = Cell.register({
    title: "Tesla",
    text: "Loading...",
    flash: false,
    refreshInterval: Time.minute(1),
    reloader: function() { renderLines() },
    onload: function() {
      this.data.refresh_timer = undefined
      this.data.loading = true
      this.data.car = {}

      renderLines()
      cell.commands.run("update")
    },
    socket: Server.socket("TeslaChannel", function(msg) {
      if (msg.loading) {
        this.data.loading = true
        renderLines()
        return
      }

      this.data.loading = false
      this.data.car = msg

      let refresh_next
      if (this.data.climate?.on || this.data.drive?.action == "driving") {
        refresh_next = Time.minute()
      } else if (this.data.charging?.active) {
        refresh_next = Time.minutes(5)
      } else {
        refresh_next = Time.hour()
      }

      clearTimeout(this.data.refresh_timer)
      this.data.refresh_timer = setTimeout(function() {
        cell.commands.run("update")
      }, refresh_next)

      renderLines()
      this.flash()
    }),
    command: function(text) {
      let [cmd, ...params] = text.split(" ")
      cell.commands.run(cmd, params.join(" "))
    },
    commands: {
      run: function(cmd, params) {
        cell.data.loading = true
        renderLines()
        cell.ws.send({ action: "command", command: cmd, params: params })
      },
      update: function() { cell.commands.run("update") },
      on: function() { cell.commands.run("on") },
      off: function() { cell.commands.run("off") },
      boot: function() { cell.commands.run("boot") },
      frunk: function() { cell.commands.run("frunk") },
      temp: function(val) { cell.commands.run("temp", val) },
      heat: function() { cell.commands.run("heat") },
    },
  })
})()