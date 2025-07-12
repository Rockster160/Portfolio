import { Text } from "../_text"
import { beep } from "../vars"

export class ListCell {
  constructor(list_name) {
    let cell = undefined
    let setList = async function(name) {
      cell.title(name)
      cell.text("Loading...")
      cell.socket?.close()

      const url = `${window.location.origin}/lists/${name}`
      cell.list = (
        await fetch(url)
          .then(res => res.json())
          .then(json => { return json })
      )

      cell.title(cell.list.name)
      cell.socket = new CellWS(
        cell,
        Server.socket({
          channel: "ListJsonChannel",
          channel_id: "list_" + cell.list.id,
        }, function(msg) {
          if (!msg.list_data) { return }

          var lines = Text.numberedList(msg.list_data.list_items)
          if (cell.text() !== "Loading...") {
            if (cell.text().length < lines.join("\n").length) {
              beep(50, 1300, 0.1, "sine") // Added
            } else if (cell.text().length > lines.join("\n").length) {
              beep(60, 800, 0.1, "sine") // Removed
            }
          }
          cell.text(lines.join("\n"))
          cell.flash()
        })
      )

      cell.socket.send({ get: true })
    }

    cell = Cell.register({
      title: list_name,
      text: "Loading...",
      wrap: true,
      onload: function() {
        setList(list_name)
      },
      reloader: function() {
        cell.socket?.send({ get: true })
      },
      commands: {
        set: function(msg) {
          setList(msg)
        }
      },
      command: function(text) {
        text = text.trim()
        if (text == "o") { return window.open("https://ardesian.com/lists/" + cell.list.name, "_blank") }

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
        } else {
          data.add = text
          delete data.message
        }

        this.socket.send(data)
      },
    })
  }
}
