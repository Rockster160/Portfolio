import { Text } from "../_text"

(function() {
  let cell = undefined

  let renderLines = function() {
    let lines = getLines()
    if (cell.data.scroll > 0) {
      lines = lines.slice(cell.data.scroll, lines.length + 1)
    }

    cell.lines(lines)
  }

  let getLines = function() {
    return localStorage.getItem("notes").split("\n")
  }

  cell = Cell.register({
    title: "Notes",
    wrap: true,
    reloader: function() {
      this.lines(getLines())
    },
    commands: {
      clear: function() {
        localStorage.removeItem("notes")
        this.text("")
      }
    },
    command: function(text) {
      var cell = this
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        lines.splice(num-1, 1)
      } else {
        var lines = cell.text() ? cell.text().split("\n") : []
        lines.push(text)
      }

      var note = Text.numberedList(lines).join("\n")

      localStorage.setItem("notes", note)
      cell.text(note)
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
        if (this.data.scroll < getLines().length) {
          this.data.scroll += 1
        }
      }

      renderLines()
    }
  })
})()
