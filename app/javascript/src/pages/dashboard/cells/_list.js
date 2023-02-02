import { Text } from "../_text"

export class ListCell {
  constructor(list_name) {
    let cell = undefined
    let setList = async function(name) {
      cell.text("Loading...")
      cell.socket?.close()

      cell.list = (
        await fetch("https://ardesian.com/lists/" + name)
          .then(res => res.json())
          .then(json => { return Array.isArray(json) ? json[0] : json })
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
          this.text(lines.join("\n"))
          this.flash()
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
        } else if (!/^(\-|\+|add|remove)/gi.test(text)) {
          data.add = text
          delete data.message
        }

        this.socket.send(data)
      },
    })
  }
}
