import { Text } from "../_text"

(function() {
  Cell.register({
    title: "Projects",
    text: "Loading...",
    wrap: true,
    socket: Server.socket({
      channel: "ListJsonChannel",
      channel_id: "list_163",
    }, function(msg) {
      if (!msg.list_data) { return }

      var lines = Text.numberedList(msg.list_data.list_items)
      this.text(lines.join("\n"))
      this.flash()
    }),
    reloader: function() {
      this.ws.send({ get: true })
    },
    command: function(text) {
      text = text.trim()
      if (text == "o") { return window.open("https://ardesian.com/lists/todo", "_blank") }

      let data = { message: text }
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = this.text().split("\n")
        var item = lines[num-1]
        data.remove = item.replace(/^\d+\. /, "")
        delete data.message
      } else if (/^\d+-\d+$/gi.test(text)) {
        data.swap = true
      } else if (/^\d+\^-?\d*$/gi.test(text)) {
        data.move = true
      } else if (/^\d+ /gi.test(text)) {
        data.rename = true
      } else if (!/^(\-|\+|add|remove)/gi.test(text)) {
        data.add = text
        delete data.message
      }

      this.ws.send(data)
    },
  })
})()
