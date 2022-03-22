(function() {
  Cell.register({
    title: "Grocery",
    text: "Loading...",
    x: 4,
    y: 4,
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
      var cell = this
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        var item = lines[num-1]
        text = "remove " + item.replace(/^\d+\. /, "")
      }

      Server.patch("/lists/grocery", { message: text })
        .fail(function(data) {
          console.log("Failed to change Grocery: ", data);
        })
    },
  })
})()
