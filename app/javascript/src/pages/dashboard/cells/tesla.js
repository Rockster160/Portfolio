import { Text } from "../_text"
import { Time } from "./_time"
import { shiftTempToColor, dash_colors, single_width } from "../vars"

(function() {
  let cell = undefined

  let renderLines = function() {
    let lines = [], data = cell.data.car
    let topchar = cell.data.loading ? "[ico ti ti-fa-spinner ti-spin]" : "  "
    let topline = topchar + " ".repeat(single_width - 2)
    if (data.charging?.state == "Disconnected") {
      topline = Text.center(Text.color(dash_colors.red, "[NOT CHARGING]"))
      topline = topline.replace(/^../, topchar)
    }
    lines.push(topline)

    let status_pieces = []
    if (data.climate?.current) {
      status_pieces.push(shiftTempToColor(data.climate.current))
    }
    status_pieces.push(Text.color(dash_colors.yellow, (data.charge || "?") + "%"))
    status_pieces.push(Text.color(dash_colors.yellow, (data.miles || "?") + "m"))
    lines.push(Text.center(status_pieces.join(" | ")))

    if (data.charging?.active && data.charging.eta > 0 && data.charging.speed > 0 && !(data.drive?.speed > 0)) {
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
      if (data.open.rd_window > 0) { opens.push("RDW") }
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
      let climate_text = "Climate: " // [ico ti ti-mdi-fan ti-spin] - Not centered, so looks weird
      climate_text += Text.color(dash_colors.green, "[ON] ")
      climate_text += shiftTempToColor(data.climate.set)
      lines.push(Text.center(climate_text))
    } else {
      lines.push(Text.center(Text.color(dash_colors.grey, "[OFF]")))
    }

    if (data.drive) {
      let lock = data.locked ? "[ico ti ti-fa-lock]" : "[ico ti ti-fa-unlock]"
      let drive_text = lock

      drive_text += "[ico ti ti-oct-location]" + data.drive.location
      if (data.drive.speed > 0) { drive_text += " [ico ti ti-mdi-speedometer]" + data.drive.speed + "mph" }
      lines.push(Text.center(Text.color(dash_colors.grey, drive_text)))
    } else {
      lines.push("")
    }

    let notify = cell.data.failed ? Text.color(dash_colors.orange, "[FAILED]") : ""
    notify = cell.data.sleeping ? Text.color(dash_colors.grey, "[sleep]") : notify
    notify = cell.data.forbidden ? Text.color(dash_colors.orange, "[AUTH]") : notify
    lines.push(Text.justify(notify, Time.timeago(data.timestamp * 1000)))

    cell.lines(lines)
  }

  let clamp = function(min, max, val) {
    return [min, max, val].sort(function(a, b) { return a - b })[1]
  }

  let resetTimeout = function(time) {
    clearTimeout(cell.data.refresh_timer)
    cell.data.refresh_timer = setTimeout(function() {
      cell.commands.run("update")
    }, time)
  }

  cell = Cell.register({
    title: "Tesla",
    text: "Loading...",
    flash: false,
    refreshInterval: Time.minute(),
    reloader: function() { renderLines() },
    onload: function() {
      this.data.refresh_timer = undefined
      this.data.loading = true
      this.data.car = {}

      renderLines()
      cell.commands.run("update")
    },
    stopped: function() {
      clearTimeout(this.data.refresh_timer)
      this.data.loading = false
      renderLines()
    },
    socket: Server.socket("TeslaChannel", function(msg) {
      this.data.sleeping = msg.sleeping
      this.data.forbidden = msg.forbidden
      if (msg.loading) {
        this.data.loading = true
        renderLines()
        return
      }

      this.data.loading = false
      this.data.car = msg

      let refresh_next
      if (this.data.car.climate?.on || this.data.car.drive?.action == "driving") {
        refresh_next = Time.minute(5)
      } else if (this.data.car.charging?.active) {
        let eta_minutes = clamp(parseInt(this.data.car.charging.eta) || 10, 1, 10)
        refresh_next = Time.minutes(eta_minutes)
      } else if (Time.now().getHours() < 7 || Time.now().getHours() > 22) { // 10pm-7am
        // Every 3 hours during night, every 1 hour during day
        refresh_next = Time.hours(3)
      } else {
        refresh_next = Time.hour()
      }

      resetTimeout(refresh_next)

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
      reload: function() { cell.commands.run("full_reload") },
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
