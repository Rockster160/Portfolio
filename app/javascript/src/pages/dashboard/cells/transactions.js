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

  function merchantName(name) {
    return name
      .replace(/Amazon web services/i, "AWS")
      .replace(/Amazon/i, "AMZ")
      .replace(/Disney Plus/i, "Disney+")
      .replace(/\.com/i, "")
      .replace(/ inc\b/i, "")
      .replace(/ #\d+/, "")
  }

  function dateLine(date) {
    return Text.center(` ${date.toDateString().replace(" 0", " ").replace(/ \d{4}/, "")} `, null, "-")
  }

  function parseTransactionLines() {
    if (!cell.data.transactions) { return renderLines() }

    let lastDateLine = dateLine(new Date())
    cell.data.lines = []
    cell.data.transactions.map(trans => {
      const { merchant, amount, account, timestamp, email_id } = trans
      const time = new Date(timestamp)
      const transDateLine = dateLine(time)

      if (lastDateLine !== transDateLine) {
        lastDateLine = transDateLine
        cell.data.lines.push(lastDateLine)
      }

      const name = Text.lblue(merchantName(merchant))
      const moneyColor = amount < 0 ? dash_colors.green : (Time.beginningOfDay() < time ? dash_colors.magenta : dash_colors.grey)
      const dollars = Text.color(moneyColor, formatCurrency(Math.abs(amount)))

      cell.data.lines.push(Text.justify(name, dollars))
    })
    renderLines()
  }

  function formatCurrency(amount) {
    return amount.toLocaleString("en-US", { style: "currency", currency: "USD" });
  }

  const dailyParse = () => setTimeout(() => parseTransactionLines() && dailyParse(), Time.msUntilNextDay())
  dailyParse()

  cell = Cell.register({
    title: "Transactions",
    text: "Loading...",
    data: { transactions: [], lines: [] },
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
        received: function(json) {
          if (json.data.transactions) {
            cell.flash()
            cell.data.transactions = json.data.transactions
            parseTransactionLines()
          } else {
            console.log("Unknown data for Monitor.transactions:", json)
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
