$(".ctr-dashboard").ready(function() {
  if (demo) { return }
  Printer = function() {}
  Printer.request = function(cell, url, type, data) {
    var url = url
    var data = data
    return $.ajax({
      url: "http://zoro-pi-1.local/api/printer" + (url || ""),
      data: JSON.stringify(data || {}),
      type: type || "GET",
      headers: {
        "X-Api-Key": authdata.printer,
        "Content-Type": "application/json"
      }
    }).fail(function(err_data) {
      var lines = [
        cell.line(0),
        url,
        data,
        JSON.stringify(err_data)
      ]
      cell.lines(lines)
    })
  }

  var printer = Cell.init({
    title: "Printer",
    text: "Loading...",
    socket: Server.socket("PrinterCallbackChannel", function(cell, msg) {
      console.log("Printer Callback", msg);
      cell.reload()
    }),
    commands: {
      gcode: function(cell, cmd) {
        return Printer.request(cell, "/command", "POST", { commands: cmd.split(", ") })
      },
      on: function(cell) {
        return Printer.request(cell, "/command", "POST", { command: "M80" })
      },
      off: function(cell) {
        cell.data.prepping = false
        return Printer.request(cell, "/command", "POST", { command: "M81" })
      },
      extrude: function(cell, amount) {
        return Printer.request(cell, "/tool", "POST", { command: "extrude", amount: amount })
      },
      retract: function(cell, amount) {
        return Printer.request(cell, "/tool", "POST", { command: "extrude", amount: "-" + amount })
      },
      home: function(cell) {
        return Printer.request(cell, "/printhead", "POST", { command: "home", axes: ["x", "y", "z"] })
      },
      move: function(cell, amounts) {
        var [x, y, z] = amounts.trim().split(" ").map(function(c) { return parseInt(c) })
        return Printer.request(cell, "/printhead", "POST", { command: "jog", x: x || 0, y: y || 0, z: z || 0 })
      },
      cool: function(cell, amounts) {
        Printer.request(cell, "/tool", "POST", { command: "target", targets: { tool0: 0 } })
        Printer.request(cell, "/bed", "POST", { command: "target", target: 0 }).done(function() {
          cell.data.prepping = true
          cell.reload()
        })
      },
      pre: function(cell) {
        cell.commands.on(cell).success(function() {
          Printer.request(cell, "/tool", "POST", { command: "target", targets: { tool0: 200 } })
          Printer.request(cell, "/bed", "POST", { command: "target", target: 40 }).done(function() {
            cell.data.prepping = true
            cell.reload()
          })
        })
      },
      showPrinting: function(cell) {
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
      },
    },
    reloader: function(cell) {
      var cell = cell
      Printer.request(cell).success(function(data) {
        var data = data
        cell.data.printing = data.state.flags.printing
        if (cell.data.printing) {
          cell.data.prepping = false
          cell.data.interval_timer = cell.data.interval_timer || setInterval(function() {
            cell.data.eta -= 1000
            if (cell.data.eta < 0) { cell.data.eta = 0 }
            cell.data.time += 1000
            cell.commands.showPrinting(cell)
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

        $.ajax({
          url: "http://zoro-pi-1.local/api/job",
          type: "GET",
          headers: {
            "X-Api-Key": authdata.printer,
            "Content-Type": "application/json"
          }
        }).success(function(data) {
          if (!data.job.user) {
            return cell.line(2, Text.center("~Cannot read from printer~"))
          }

          cell.data.now = Time.msSinceEpoch()
          cell.data.progress = data.progress.completion
          cell.data.eta = data.progress.printTimeLeft * 1000
          cell.data.time = data.progress.printTime * 1000
          cell.data.estimated = data.job.estimatedPrintTime * 1000
          cell.data.filename = data.job.file.display.replace(/-?(\d+D)?(\d+H)?(\d+M)?\.gcode$/i, "")
          cell.data.eta_ms = data.progress.completion == 100 ? cell.data.eta_ms : cell.data.now + cell.data.eta
          cell.commands.showPrinting(cell)
        })
      })
    },
  })
})

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
