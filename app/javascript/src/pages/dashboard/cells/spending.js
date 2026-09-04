import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, clamp } from "../vars"

// Health bars for the month's money: how much is left on the month, the
// trailing week and today, over how much of the month itself is left to spend
// it in. Read the top bar against the three below it — money draining faster
// than the clock is the thing this cell exists to show, and it is a SHAPE, not
// a sum. Only the date carries a number; a glance should not be a reckoning.
//
// The server sends DAILY BUCKETS, not the three totals, so the sums happen
// here against the browser's own clock. That is what makes a dashboard left
// open overnight roll onto the new day at 3am without anything being pushed to
// it — nothing writes to the bank at 3am to say the day changed.
(function() {
  let cell = undefined

  const cell_width = 32
  const cell_height = 9
  // One space of margin either side, same as the Timers cell it replaced.
  const bar_width = cell_width - 2
  // The day rolls at 3am, not midnight — matches User#perceived_today and
  // Buddy::Day on the server, and agenda.js on this side.
  const rollover_hour = 3

  // A blank line, not "": the renderer measures line height off content.
  const blank = " ".repeat(cell_width)

  const month_names = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ]

  function perceivedDate(date) {
    const day = new Date(date.getTime())
    if (day.getHours() < rollover_hour) { day.setDate(day.getDate() - 1) }
    day.setHours(0, 0, 0, 0)
    return day
  }

  function dateKey(date) {
    return [
      date.getFullYear(),
      String(date.getMonth() + 1).padStart(2, "0"),
      String(date.getDate()).padStart(2, "0"),
    ].join("-")
  }

  function daysInMonth(date) {
    return new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate()
  }

  // `count` perceived days starting at `from`. A day nobody spent on has no
  // bucket, and a missing bucket is zero — which is what it was.
  function spentOver(from, count) {
    const days = cell.data.days || {}
    let total = 0
    for (let idx = 0; idx < count; idx++) {
      const day = new Date(from.getTime())
      day.setDate(day.getDate() + idx)
      total += days[dateKey(day)] || 0
    }
    return total
  }

  // Green while there is room, yellow on the last quarter, red once it is
  // gone. An overspent bar is drawn full rather than empty: an empty red
  // sliver reads as "nearly out" when it means the opposite.
  function spendColor(fraction) {
    if (fraction <= 0) { return dash_colors.red }
    if (fraction <= 0.25) { return dash_colors.yellow }
    return dash_colors.green
  }

  function bar(text, fraction, color) {
    text = text.padEnd(bar_width, " ").slice(0, bar_width)

    const filled = clamp(Math.round(bar_width * fraction), 0, bar_width)

    return " " +
      Text.bgColor(color, text.slice(0, filled)) +
      Text.bgColor(dash_colors.darkgrey, text.slice(filled)) +
      " "
  }

  // Deliberately carries no figure. How full it is IS the answer, and the
  // dollars are a step down into the Transactions cell next to it.
  function spendBar(label, spent_cents, budget_cents) {
    const fraction = budget_cents > 0 ? (budget_cents - spent_cents) / budget_cents : 0

    return bar("  " + label, fraction <= 0 ? 1 : fraction, spendColor(fraction))
  }

  function render() {
    const now = new Date()
    const today = perceivedDate(now)
    cell.data.day_key = dateKey(today)

    const in_month = daysInMonth(today)
    const day_of_month = today.getDate()
    const month_start = new Date(today.getTime())
    month_start.setDate(1)

    const month_budget = cell.data.budget_cents || 0
    const day_budget = month_budget / in_month
    const week_budget = day_budget * 7

    const week_start = new Date(today.getTime())
    week_start.setDate(week_start.getDate() - 6)

    const days_left = in_month - day_of_month

    const lines = [
      bar(
        Text.justify(
          bar_width,
          "  " + month_names[today.getMonth()],
          "day " + day_of_month + " of " + in_month + "  ",
        ),
        days_left / in_month,
        dash_colors.lblue,
      ),
      blank,
      blank,
      spendBar("Month", spentOver(month_start, day_of_month), month_budget),
      blank,
      spendBar("Week", spentOver(week_start, 7), week_budget),
      blank,
      spendBar("Today", spentOver(today, 1), day_budget),
      blank,
    ]

    cell.lines(lines.slice(0, cell_height))
  }

  cell = Cell.register({
    title: "Spending",
    text: "Loading...",
    data: { budget_cents: 0, days: {}, day_key: undefined },
    // Only the clock moves between pushes, and it only matters at the 3am
    // rollover and the turn of the month. Redrawing is free; a resync runs a
    // Jil task, so it waits for the day to actually have changed.
    refreshInterval: Time.minutes(5),
    reloader: function() {
      const rolled = cell.data.day_key && cell.data.day_key !== dateKey(perceivedDate(new Date()))
      if (rolled) { cell.monitor?.resync() }

      render()
    },
    onload: function() {
      cell.monitor = Monitor.subscribe("spending", {
        connected: function() {
          cell.monitor?.resync()
        },
        disconnected: function() {},
        received: function(json) {
          const data = json.data || {}
          if (data.budget_cents === undefined) {
            return console.log("Unknown data for Monitor.spending:", json)
          }

          cell.flash()
          cell.data.budget_cents = data.budget_cents
          cell.data.days = data.days || {}
          render()
        },
      })
    },
  })
})()
