import { Time } from "./_time"
import { Text } from "../_text"
import { text_height, dash_colors } from "../vars"

(function() {
  let cell = undefined

  const clamp = (num, min, max) => Math.min(Math.max(num, min), max);

  let renderLines = function() {
    let lines = cell.data.lines
    cell.lines(lines)

    let content = cell.ele[0].querySelector(".dash-content")
    let max_lines = (content.scrollHeight - content.clientHeight)/text_height

    if (cell.livekey_active) {
      cell.data.scroll = clamp(cell.data.scroll, 0, max_lines)
    } else {
      cell.data.scroll = max_lines
    }

    content.scroll({ top: cell.data.scroll * text_height })
  }

  cell = Cell.register({
    title: "JS",
    wrap: true,
    data: {
      lines: localStorage.getItem("js")?.split("\n") || [],
    },
    onload: function() {
      localStorage.getItem("js")?.split("\n")?.forEach(function(line) {
        if (line.trim().length > 0 && line.includes("[color")) { return }
        try { (0, eval)(line) } catch {}
      })
      renderLines()
    },
    commands: {
      clear: function() {
        localStorage.setItem("js", [])
        cell.data.lines = []
        renderLines()
      }
    },
    command: function(msg) {
      this.data.lines.push(msg)
      renderLines()
      try {
        if (msg.trim().length > 0) {
          this.data.lines.push(Text.grey("=> " + JSON.stringify((0, eval)(msg))))
        }
      } catch(e) {
        this.data.lines.push(Text.red(e))
      }
      renderLines()
      localStorage.setItem("js", this.data.lines.join("\n"))
    },
    onfocus: function() { renderLines() },
    onblur: function() { renderLines() },
    livekey: function(evt_key) {
      this.data.scroll = this.data.scroll || 0

      evt_key = evt_key.toLowerCase()
      if (evt_key == "arrowup" || evt_key == "w") { this.data.scroll -= 1 }
      if (evt_key == "arrowdown" || evt_key == "s") { this.data.scroll += 1 }

      renderLines()
    }
  })
})()
