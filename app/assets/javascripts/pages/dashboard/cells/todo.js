$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  Cell.init({
    title: "TODO",
    text: "Loading...",
    x: 3,
    y: 4,
    socket: Server.socket({
      channel: "ListChannel",
      channel_id: "list_5",
    }, function(cell, msg) {
      if (!msg.list_data) { return }

      var lines = Text.numberedList(msg.list_data.list_items)
      cell.text(lines.join("\n"))
    }),
    reloader: function(cell) {
      $.getJSON("/lists/todo", function(data) {
        var lines = Text.numberedList(data.list_items)
        cell.text(lines.join("\n"))
      }).fail(function(data) {
        cell.text("Failed to retrieve: " + JSON.stringify(data))
      })
    },
    command: function(text, cell) {
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        var item = lines[num-1]
        text = "remove " + item.replace(/^\d+\. /, "")
      }

      Server.patch("/lists/todo", { message: text })
        .fail(function(data) {
          console.log("Failed to change TODO: ", data);
        })
    },
  })
})
