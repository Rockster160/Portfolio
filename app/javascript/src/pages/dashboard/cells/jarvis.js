// import { Text } from "../_text"
// import { Time } from "./_time"
// import { shiftTempToColor, dash_colors } from "../vars"

(function() {
  let cell = undefined

  let renderLines = function(history) {
    cell.lines(history || getHistory())
  }

  let getHistory = function() {
    return localStorage.getItem("jarvis_history")?.split("\n")?.slice(0, 50) || []
  }

  let saveHistory = function(lines) {
    return localStorage.setItem("jarvis_history", lines.join("\n") || [])
  }

  cell = Cell.register({
    title: "Jarvis",
    text: "Loading...",
    onload: function() { renderLines() },
    socket: Server.socket("JarvisChannel", function(msg) {
      if (msg.response?.trim().length == 0) { msg.response = "<No response>" }
      // TODO: Do stuff with msg.data

      let history = getHistory()
      history.unshift(msg.response)
      saveHistory(history)

      renderLines(history)
      this.flash()
    }),
    command: function(text) {
      cell.lines(["[ico ti ti-fa-spinner ti-spin]", ...getHistory()])
      cell.ws.send({ action: "command", words: text })
    },
    commands: {
      clear: function() {
        localStorage.setItem("jarvis_history", "")
        this.text("")
      }
    },
  })
})()
