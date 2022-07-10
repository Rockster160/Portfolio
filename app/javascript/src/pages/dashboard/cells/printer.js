import { Text } from "../_text"
import { Time } from "./_time"

(function() {
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

  var showPrinting = function(cell) {
    var lines = [cell.line(0), ""]
    lines.push(Text.center(cell.data.filename))
    lines.push(Text.progressBar(cell.data.progress, { post_text: Math.round(cell.data.progress) + "%"}))
    lines.push(Text.justify("       ETA: ", Time.duration(cell.data.eta) + "       "))
    lines.push(Text.justify("       Current: ", Time.duration(cell.data.time) + "       "))
    lines.push(Text.justify("       Est: ", Time.duration(cell.data.estimated) + "       "))
    if (cell.data.eta_ms) {
      lines.push(Text.justify("       Complete: ", Time.local(cell.data.eta_ms) + "       "))
    }
    cell.lines(lines)
  }

  var printer = Cell.register({
    title: "Printer",
    text: "Loading...",
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
        var data = data
        cell.data.printing = data.state.flags.printing
        if (cell.data.printing) {
          cell.data.prepping = false
          cell.data.interval_timer = cell.data.interval_timer || setInterval(function() {
            cell.data.eta -= 1000
            if (cell.data.eta < 0) { cell.data.eta = 0 }
            cell.data.time += 1000
            showPrinting(cell)
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
        cell.line(0, Text.center([tool, bed].join(" | ")))

        Printer.post("job").done(function(data) {
          if (!data.job.user) {
            return cell.line(2, Text.center("~Previous job unavailable~"))
          }

          cell.data.now = Time.msSinceEpoch()
          cell.data.progress = data.progress.completion
          cell.data.eta = data.progress.printTimeLeft * 1000
          cell.data.time = data.progress.printTime * 1000
          cell.data.estimated = data.job.estimatedPrintTime * 1000
          cell.data.filename = data.job.file.display.replace(/-?(\d+D)?(\d+H)?(\d+M)?\.gcode$/i, "")
          cell.data.eta_ms = data.progress.completion == 100 ? cell.data.eta_ms : cell.data.now + cell.data.eta
          showPrinting(cell)
        })
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
