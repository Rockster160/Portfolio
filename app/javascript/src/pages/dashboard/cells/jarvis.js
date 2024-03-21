import { Time } from "./_time"

(function() {
  let cell = undefined

  let renderLines = function(history) {
    cell.lines((history || getHistory()).slice(cell.data.scroll || 0, 50))
  }

  let getHistory = function() {
    return localStorage.getItem("jarvis_history")?.split("\n")?.slice(0, 50) || []
  }

  let saveHistory = function(lines) {
    return localStorage.setItem("jarvis_history", lines.join("\n") || [])
  }

  cell = Cell.register({
    title: "Jarvis",
    wrap: true,
    onload: function() {
      this.data.scroll = 0
      renderLines()
    },
    socket: Server.socket("JarvisChannel", function(msg) {
      // TODO: Do stuff with msg.data
      if (msg.say?.trim()?.length > 0)  {
        let history = getHistory()
        if (/^Logged \w( |\*|ish|$)/.test(msg.say)) { return renderLines(history) }
        if (!/^Logged /.test(msg.say) || /\[/.test(msg.say)) {
          history.unshift("[" + Time.local() + "] " + msg.say)
          saveHistory(history)
        }

        renderLines(history)
      }

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
    onfocus: function() {
      this.data.scroll = 0
      renderLines()
    },
    onblur: function() {
      this.data.scroll = 0
      renderLines()
    },
    livekey: function(evt_key) {
      this.data.scroll = this.data.scroll || 0

      evt_key = evt_key.toLowerCase()
      if (evt_key == "arrowup" || evt_key == "w") {
        if (this.data.scroll > 0) {
          this.data.scroll -= 1
        }
      } else if (evt_key == "arrowdown" || evt_key == "s") {
        if (this.data.scroll < getHistory().length) {
          this.data.scroll += 1
        }
      }

      renderLines()
    }
  })
})()
