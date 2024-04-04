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

  let timestamp = function(elapsedTime) {
    if (elapsedTime) {
      return Time.duration(elapsedTime)
    } else {
      return "??:??:??"
    }
  }

  let timestampToDuration = function(elapsedTime) {
    let duration = Time.duration(elapsedTime)
    let [h, m, s] =  duration.split(":").map(Number)
    let parts = []
    if (h > 0) { parts.push(`${h}h`) }
    if (m > 0) { parts.push(`${m}m`) }
    if (s > 0) { parts.push(`${s}s`) }
    return parts.join("")
  }

  var renderLines = function() {
    if (!cell) { return cell.lines("Loading...") }
    if (!cell.data.temps.tool || cell.data.fail) {
      return cell.lines(["", "", "", Text.center(Text.color(dash_colors.red, "[ERROR]"))])
    }
    let printer_data = cell.data.printer_data || {}

    let lines = []
    lines.push(Text.center([cell.data.temps.tool, cell.data.temps.bed].join(" | ")))
    lines.push("")
    lines.push(Text.center(printer_data.filename || "[Job not found]"))

    if (printer_data.filename) {
      let progress_bar = (printer_data.progress == 0 || printer_data.progress) ? Text.progressBar(printer_data.progress) : ""
      let elapsed = timestampToDuration(printer_data.elapsedTime)
      let remaining = timestampToDuration(printer_data.timeLeft)
      let eta = (printer_data.eta_ms ? Time.local(printer_data.eta_ms) : "??:??")
      let estimated = timestampToDuration(printer_data.estimated)

      lines.push(progress_bar)
      lines.push(Text.center(elapsed + " / " + estimated))
      lines.push(Text.center("ETA: " + eta + " (" + remaining + ")"))
    }

    cell.lines(lines)

    if (cell.data.lastUpdated < Time.now() + Time.minutes(6)) {
      return cell.line(9, Text.justify("", Text.color(dash_colors.orange, "[EXPIRED]")))
    }
  }

  cell = Cell.register({
    title: "Printer",
    text: "Loading...",
    data: { lastUpdated: Time.now() },
    socket: Server.socket("PrinterCallbackChannel", function(msg) {
      console.log(`%${msg?.printer_data?.progress?.completion}%`, msg);
      cell.data.lastUpdated = Time.msSinceEpoch()
      let data = msg.printer_data
      if (!data) {
        return // Should probably be a failed state
      }
      cell.data.printing = data.state?.flags?.printing
      if (cell.data.printing) {
        cell.data.prepping = false
        cell.data.interval_timer = cell.data.interval_timer || setInterval(function() {
          cell.data.printer_data.timeLeft -= 1000
          if (cell.data.printer_data.timeLeft < 0) { cell.data.printer_data.timeLeft = 0 }
          cell.data.printer_data.elapsedTime = (cell.data.printer_data.elapsedTime || 0) + 1000
          renderLines()
        }, 1000)
      } else if (!cell.data.prepping) {
        clearInterval(cell.data.interval_timer)
        cell.data.interval_timer = null
      }
      // FIXME: Temps aren't coming through
      var tool = Emoji.pen + (Math.round(data.temperature?.tool0?.actual) || "?") + "°"
      var bed = Emoji.printer + " " + (Math.round(data.temperature?.bed?.actual) || "?") + "°"
      if (data.temperature?.tool0?.target - (0.5 > data.temperature?.tool0?.actual)) {
        tool = tool + " (" + (Math.round(data.temperature?.tool0?.target) || "?") + ")"
      }
      if (data.temperature?.bed?.target - (0.5 > data.temperature?.bed?.actual)) {
        bed = bed + " (" + (Math.round(data.temperature?.bed?.target) || "?") + ")"
      }
      cell.data.temps = {
        tool: tool,
        bed: bed,
      }

      let printer_data = {}
      printer_data.msSinceEpoch = Time.msSinceEpoch()
      if (data.progress) {
        printer_data.progress = data.progress.completion
        printer_data.timeLeft = data.progress.printTimeLeft * 1000
        printer_data.elapsedTime = data.progress.printTime * 1000
        printer_data.eta_ms = data.progress.completion == 100 ? printer_data.elapsedTime : printer_data.msSinceEpoch + printer_data.timeLeft
      }
      if (data.job) {
        printer_data.estimated = data.job.estimatedPrintTime * 1000
      }
      let filename = (data.job?.file?.display || data?.extra?.name)?.replace(/-?(\d+D)?(\d+H)?(\d+M)?\.gcode$/i, "")
      if (filename) { printer_data.filename = filename }

      cell.data.printer_data = printer_data
      renderLines()
    }),
    command: function(words) {
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
  })
})()

// {
//   "deviceIdentifier": "zoro-pi-1",
//   "topic": "Print Progress",
//   "message": "Your print is 2 % complete.",
//   "extra": {},
//   "state": {
//     "text": "Printing",
//     "flags": {
//       "operational": true,
//       "printing": true,
//       "cancelling": false,
//       "pausing": false,
//       "resuming": false,
//       "finishing": false,
//       "closedOrError": false,
//       "error": false,
//       "paused": false,
//       "ready": false,
//       "sdReady": false
//     },
//     "error": ""
//   },
//   "job": {
//     "file": {
//       "name": "Slime-24M.gcode",
//       "path": "Slime-24M.gcode",
//       "display": "Slime-24M.gcode",
//       "origin": "local",
//       "size": 908307,
//       "date": 1712114222
//     },
//     "estimatedPrintTime": 1155.7580897501998,
//     "averagePrintTime": null,
//     "lastPrintTime": null,
//     "filament": {
//       "tool0": {
//         "length": 954.1910799999978,
//         "volume": 0.0
//       }
//     },
//     "user": "Rockster160"
//   },
//   "progress": {
//     "completion": 2.0033975296898516,
//     "filepos": 18197,
//     "printTime": 272,
//     "printTimeLeft": 1011,
//     "printTimeLeftOrigin": "analysis"
//   },
//   "currentZ": 0.94,
//   "offsets": {},
//   "meta": {
//     "hash": "aa1da4cb07cc5385a0a5d80a8c7c2907c9e919fe",
//     "analysis": {
//       "printingArea": {
//         "maxX": 121.848,
//         "maxY": 200.0,
//         "maxZ": 21.94,
//         "minX": 0.1,
//         "minY": 20.0,
//         "minZ": 0.0
//       },
//       "dimensions": {
//         "depth": 180.0,
//         "height": 21.94,
//         "width": 121.748
//       },
//       "travelArea": {
//         "maxX": 121.848,
//         "maxY": 220.0,
//         "maxZ": 32.14,
//         "minX": 0.0,
//         "minY": 0.0,
//         "minZ": 0.0
//       },
//       "travelDimensions": {
//         "depth": 220.0,
//         "height": 32.14,
//         "width": 121.848
//       },
//       "estimatedPrintTime": 1155.7580897501998,
//       "filament": {
//         "tool0": {
//           "length": 954.1910799999978,
//           "volume": 0.0
//         }
//       }
//     }
//   },
//   "currentTime": 1712114536,
//   "controller": "webhooks",
//   "action": "notify"
// }
