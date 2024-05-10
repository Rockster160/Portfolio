import { createConsumer } from "@rails/actioncable"
// import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, text_height } from "../vars"

(function() {
  let cell = undefined

  const clamp = (num, min, max) => Math.min(Math.max(num, min), max);

  let renderLines = function() {
    let lines = cell.data?.lines || []
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
    title: "broker_logger",
    data: {
      lines: localStorage.getItem("broker_logger")?.split("\n") || [],
    },
    // socket: Server.socket("AgentsChannel", function(msg) {
    //   // Catch errors, too?
    //   let agent = msg.log.agent == "Murton, Brendan" ? "B" : msg.log.agent.split(", ")[1][0]
    //   let arrows = {
    //     right: "ﰲ",
    //     up:    "ﰵ",
    //     left:  "ﰯ",
    //     down:  "ﰬ",
    //   }
    //   let methodArr = {
    //     get: Text.color(dash_colors.yellow, arrows.left),
    //     post: Text.color(dash_colors.blue, arrows.right),
    //     patch: Text.color(dash_colors.orange, arrows.up),
    //     put: Text.color(dash_colors.magenta, arrows.up),
    //     delete: Text.color(dash_colors.orange, arrows.down),
    //   }
    //   let method = methodArr[msg.log.method.toLowerCase()]
    //   let path = msg.log.path
    //   let params = JSON.stringify(msg.log.params).replaceAll(/\"(\w+)\":/g, "$1:")
    //
    //   this.data.lines.push(`${method} ${agent} ${path} ${params}`)
    //   renderLines()
    //   localStorage.setItem("broker_logger", this.data.lines.join("\n"))
    // }, "https://itswildcat.com"),
    onload: function() {
      renderLines()
      cell.data.consumer = createConsumer.create('wss://itswildcat.com/cable', {
        headers: {
          Authorization: `Bearer ${cell.config.apikey}`,
        }
      });
      cell.data.subscription = cell.data.consumer.subscriptions.create("AgentsChannel", {
        connected() {
          console.log("Connected to WebSocket server");
        },
        received(data) {
          console.log("Received data from server:", data);
        }
      });
    },
    // commands: {
    //   clear: function() {
    //     localStorage.setItem("js", [])
    //     cell.data.lines = []
    //     renderLines()
    //   }
    // },
    // command: function(msg) {
    //   this.data.lines.push(msg)
    //   renderLines()
    //   try {
    //     if (msg.trim().length > 0) {
    //       this.data.lines.push(Text.color(dash_colors.grey, "=> " + JSON.stringify((0, eval)(msg))))
    //     }
    //   } catch(e) {
    //     this.data.lines.push(Text.color(dash_colors.red, e))
    //   }
    //   renderLines()
    //   localStorage.setItem("js", this.data.lines.join("\n"))
    // },
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
