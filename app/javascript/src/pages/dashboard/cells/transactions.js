import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, text_height, clamp } from "../vars"

(function() {
  let cell = undefined

  let renderLines = function() {
    let lines = cell.data.lines
    cell.lines(lines)

    let content = cell.ele[0].querySelector(".dash-content")
    let max_lines = (content.scrollHeight - content.clientHeight)/text_height

    if (cell.livekey_active) {
      cell.data.scroll = clamp(cell.data.scroll, 0, max_lines)
    } else {
      cell.data.scroll = 0
    }

    content.scroll({ top: cell.data.scroll * text_height })
  }

  function formatCurrency(amount) {
    return amount.toLocaleString("en-US", { style: "currency", currency: "USD" });
  }

  cell = Cell.register({
    title: "Transactions",
    text: "Loading...",
    data: { lines: [] },
    refreshInterval: Time.hour(),
    reloader: function() {
      var cell = this
      cell.monitor?.resync()
    },
    onload: function() {
      cell.monitor = Monitor.subscribe("transactions", {
        connected: function() {
          cell.monitor?.resync()
        },
        disconnected: function() {},
        received: function(data) {
          if (data.data.transactions) {
            cell.flash()
            cell.data.lines = data.data.transactions.map(trans => {
              const { merchant, amount, account, timestamp, email_id } = trans
              const name = Text.rocco(merchant)
              const moneyColor = amount >= 0 ? dash_colors.grey : dash_colors.green
              const dollars = Text.color(moneyColor, formatCurrency(Math.abs(amount)))

              return Text.justify(name, dollars)
            })
            renderLines()
          } else {
            console.log("Unknown data for Monitor.transactions:", data)
          }
        },
      })
    },
    onfocus: function() { renderLines() },
    onblur: function() { renderLines() },
    livekey: function(evt_key) {
      this.data.scroll = this.data.scroll || 0

      evt_key = evt_key.toLowerCase()
      if (evt_key == "arrowup" || evt_key == "w") { this.data.scroll -= 1 }
      if (evt_key == "arrowdown" || evt_key == "s") { this.data.scroll += 1 }

      renderLines()
    },
    command: function(text) {
      // return window.open("https://ardesian.com/scheduled", "_blank")
    }
  })
})()
