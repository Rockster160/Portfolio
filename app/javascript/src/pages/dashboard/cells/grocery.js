import { Text } from "../_text"

(function() {
  Cell.register({
    title: "Grocery",
    text: "Loading...",
    wrap: true,
    socket: Server.socket({
      channel: "ListChannel",
      channel_id: "list_1",
    }, function(msg) {
      if (!msg.list_data) { return }

      var lines = Text.numberedList(msg.list_data.list_items)
      this.text(lines.join("\n"))
    }),
    reloader: function() {
      var cell = this
      $.getJSON("/lists/grocery", function(data) {
        var lines = Text.numberedList(data.list_items)
        cell.text(lines.join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + JSON.stringify(data))
      })
    },
    command: function(text) {
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = this.text().split("\n")
        var item = lines[num-1]
        text = "remove " + item.replace(/^\d+\. /, "")
      }
      if (!/^[-|+|add|remove]/gi.test(text)) {
        text = "add " + text
      }

      Server.patch("/lists/grocery", { message: text })
        .fail(function(data) {
          console.log("Failed to change Grocery: ", data);
        })
    },
  })
})()
