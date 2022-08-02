import { Text } from "../_text"
import { Time } from "./_time"
import { dash_colors } from "../vars"

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

  let paddedLineFromData = function(str, duration) {
    if (!duration) { return "" }
    let pad = "       "
    return Text.justify(pad + str + ": ", duration + pad)
  }

  var renderLines = function() {
    if (!cell) { return cell.lines("Loading...") }
    if (!cell.data.temps.tool || cell.data.fail) {
      return cell.lines(["", "", "", Text.center(Text.color(dash_colors.red, "[ERROR]"))])
    }

    var lines = [
      Text.center([cell.data.temps.tool, cell.data.temps.bed].join(" | ")),
      "",
      Text.center(cell.data.filename || "[Job not found]"),
      (cell.data.progress == 0 || cell.data.progress) ? Text.progressBar(cell.data.progress, { post_text: Math.round(cell.data.progress) + "%"}) : "",
      paddedLineFromData("ETA", cell.data.eta ? Time.duration(cell.data.eta) : ""),
      paddedLineFromData("Current", cell.data.time ? Time.duration(cell.data.time) : ""),
      paddedLineFromData("Est", cell.data.estimated ? Time.duration(cell.data.estimated) : ""),
      paddedLineFromData("Complete", cell.data.eta_ms ? Time.local(cell.data.eta_ms) : ""),
      "",
      Text.justify("", Text.color(dash_colors.orange, "[EXPIRED]")),
    ]

    cell.lines(lines)

    if (cell.data.lastUpdated < Time.now() + Time.minutes(6)) {
      return cell.line(9, Text.justify("", Text.color(dash_colors.orange, "[EXPIRED]")))
    }
  }

  cell = Cell.register({
    title: "Printer",
    text: "Loading...",
    data: {
      lastUpdated: Time.now()
    },
    commands: {
      gcode: function(cmd) {
        return Printer.post("command", cmd)
      },
      on: function() {
        return Printer.post("on")
      },
      off: function() {
        this.data.prepping = false
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
        Printer.post("cool")
        cell.data.prepping = true
        cell.reload()
      },
      pre: function() {
        Printer.post("pre")
        cell.data.prepping = true
        cell.reload()
      },
    },
    reloader: function() {
      var cell = this
      // =========================================
      Printer.post("printer").done(function(data) {
        cell.data.lastUpdated = Time.msSinceEpoch()
        var data = data
        cell.data.printing = data.state.flags.printing
        if (cell.data.printing) {
          cell.data.prepping = false
          cell.data.interval_timer = cell.data.interval_timer || setInterval(function() {
            cell.data.eta -= 1000
            if (cell.data.eta < 0) { cell.data.eta = 0 }
            cell.data.time += 1000
            renderLines()
          }, 1000)
        }
        if (cell.data.printing || cell.data.prepping) {
          cell.resetTimer(Time.seconds(5))
        } else {
          cell.resetTimer(Time.minutes(5))
          clearInterval(cell.data.interval_timer)
          cell.data.interval_timer = null
        }

        var tool = Emoji.pen + Math.round(data.temperature.tool0.actual) + "°"
        var bed = Emoji.printer + " " + Math.round(data.temperature.bed.actual) + "°"
        if (data.temperature.tool0.target - 0.5 > data.temperature.tool0.actual) {
          tool = tool + " (" + Math.round(data.temperature.tool0.target) + ")"
        }
        if (data.temperature.bed.target - 0.5 > data.temperature.bed.actual) {
          bed = bed + " (" + Math.round(data.temperature.bed.target) + ")"
        }
        cell.data.temps = {
          tool: tool,
          bed: bed,
        }
        renderLines()

        Printer.post("job").done(function(data) {
          cell.data.fail = false
          if (!data.job.user) {
            cell.data.printer_data = {}
            return renderLines()
          }
          let printer_data = {}

          printer_data.msSinceEpoch = Time.msSinceEpoch()
          printer_data.progress = data.progress.completion
          printer_data.eta = data.progress.printTimeLeft * 1000
          printer_data.time = data.progress.printTime * 1000
          printer_data.estimated = data.job.estimatedPrintTime * 1000
          printer_data.filename = data.job.file.display.replace(/-?(\d+D)?(\d+H)?(\d+M)?\.gcode$/i, "")
          printer_data.eta_ms = data.progress.completion == 100 ? printer_data.eta_ms : printer_data.now + printer_data.eta

          cell.data.printer_data = printer_data
          renderLines()
        })
      }).fail(function(data) {
        cell.data.fail = true
        renderLines()
      })
    },
  })
})()

// {
//   "job": {
//     "averagePrintTime": 1092.872925517986,
//     "estimatedPrintTime": 967.5191510104092,
//     "filament": {
//       "tool0": {
//         "length": 1494.6377851781435,
//         "volume": 3.5950251749839905
//       }
//     },
//     "file": {
//       "date": 1640306690,
//       "display": "glassboard_clip-16M.gcode",
//       "name": "glassboard_clip-16M.gcode",
//       "origin": "local",
//       "path": "glassboard_clip-16M.gcode",
//       "size": 570671
//     },
//     "lastPrintTime": 1036.803297137958,
//     "user": "Rockster160"
//   },
//   "progress": {
//     "completion": 46.62213429454099,
//     "filepos": 266059,
//     "printTime": 540,
//     "printTimeLeft": 442,
//     "printTimeLeftOrigin": "genius"
//   },
//   "state": "Printing"
// }
