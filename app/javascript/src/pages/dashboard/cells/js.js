import { Time } from "./_time"

(function() {
  let cell = undefined

  let renderLines = function() {
    let lines = cell.data.lines
    if (cell.data.scroll > 0) {
      lines = lines.slice(cell.data.scroll, lines.length + 1)
    }

    cell.lines(lines)
  }

  cell = Cell.register({
    title: "JS",
    wrap: true,
    data: {
      lines: [],
    },
    command: function(msg) {
      this.data.lines.push(msg)
      renderLines()
      this.data.lines.push("[color grey]=> " + eval(msg) + "[/color]")
      renderLines()
    },
    onfocus: function() {
      this.data.scroll = cell.data.lines.length - 9
      renderLines()
    },
    onblur: function() {
      this.data.scroll = cell.data.lines.length - 9
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
        if (this.data.scroll < cell.data.lines.length) {
          this.data.scroll += 1
        }
      }

      renderLines()
    }
  })
})()
