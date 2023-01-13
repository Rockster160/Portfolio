import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, text_height } from "../vars"

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
    title: "BrokerLogger",
    data: {
      lines: localStorage.getItem("broker_logger")?.split("\n") || [],
    },
    refreshInterval: Time.msUntilNextDay(),
    reloader: function() {
      var cell = this
      cell.refreshInterval = Time.msUntilNextDay()
      if (cell.refreshInterval < Time.hours(23)) { return }
      let date = (new Date).toDateString()

      cell.data.lines.push(Text.center(`  ${date}  `, null, "-"))
      cell.data.lines = cell.data.lines.slice(-100)
      renderLines()
      localStorage.setItem("broker_logger", cell.data.lines.join("\n"))
    },
    onload: function() {
      this.ws = new CellWS(this,
        Server.socket("AgentsChannel", function(msg) {
          // Catch errors, too?
          let agent = Text.color(dash_colors.orange, msg.log.agent.split(", ").slice(-1)[0])
          if (msg.log.agent == "Murton, Brendan") {
            agent = Text.color(dash_colors.green, "B")
          } else if (msg.log.agent == "Nicholls, Rocco") {
            agent = Text.color(dash_colors.rocco, "R")
          } else if (msg.log.agent == "Barker, Derek") {
            agent = Text.color(dash_colors.magenta, "D")
          }
          let arrows = {
            right: "ﰲ",
            up:    "ﰵ",
            left:  "ﰯ",
            down:  "ﰬ",
          }
          let methodArr = {
            get: Text.color(dash_colors.yellow, arrows.left),
            post: Text.color(dash_colors.blue, arrows.right),
            patch: Text.color(dash_colors.orange, arrows.up),
            put: Text.color(dash_colors.magenta, arrows.up),
            delete: Text.color(dash_colors.orange, arrows.down),
          }
          let method = methodArr[msg.log.method.toLowerCase()]
          let path = msg.log.path
          let params = Text.color(dash_colors.grey, JSON.stringify(msg.log.params).replaceAll(/\"(\w+)\":/g, "$1:"))
          let time = Time.local()

          this.data.lines.push(Text.justify(`${method} ${agent} ${path}`, time))
          if (Object.keys(msg.log.params).length > 0) {
            this.data.lines.push(`  ${params}`)
          }
          this.data.lines = this.data.lines.slice(-100)
          renderLines()
          localStorage.setItem("broker_logger", this.data.lines.join("\n"))
        }, "https://itswildcat.com?Authorization=Basic%20" + this.config.broker_auth)
        // }, "http://localhost:3315?Authorization=Basic%20" + this.config.broker_auth)
      )
      renderLines()
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
