import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, clamp } from "../vars"

// Health bars for the month's money: how much is left on the month, the
// trailing week and today, over how much of the month itself is left to spend
// it in. Read the top bar against the three below it — money draining faster
// than the clock is the thing this cell exists to show, and it is a SHAPE, not
// a sum. Only the date carries a number at rest; a glance should not be a
// reckoning. Hover a bar and its own line spells the money out, in place.
//
// The server sends DAILY BUCKETS, not the three totals, so the sums happen
// here against the browser's own clock. That is what makes a dashboard left
// open overnight roll onto the new day at 3am without anything being pushed to
// it — nothing writes to the bank at 3am to say the day changed.
//
// The Caffeine bar at the bottom is the odd one out: it counts UP, filling as
// the day's milligrams land rather than draining as they go. Its buckets
// arrive in the same payload for the same reason — one cell, one broadcast.
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
  // Where the bars sit in the rendered lines — `hover` reports a line index,
  // and only these four answer to it. The three money bars stack with nothing
  // between them: they are one reading, and the gaps made them look like three
  // unrelated ones. The blanks that are left separate the three GROUPS — the
  // clock, the money, the caffeine.
  const month_row = 3
  const week_row = 4
  const today_row = 5
  const caffeine_row = 8

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

  function money(cents) {
    const dollars = Math.round(cents / 100)
    const sign = dollars < 0 ? "-" : ""
    return sign + "$" + Math.abs(dollars).toLocaleString("en-US")
  }

  // Takes what is LEFT, not what has gone: green while there is room, yellow
  // on the last quarter, red once it is gone. Both directions of bar read off
  // this, so a full red bar means the same thing whichever way it filled.
  //
  // An overspent bar is drawn full rather than empty: an empty red sliver
  // reads as "nearly out" when it means the opposite.
  function roomColor(fraction) {
    if (fraction <= 0) { return dash_colors.red }
    if (fraction <= 0.25) { return dash_colors.yellow }
    return dash_colors.green
  }

  // Which ink the label can be read in ON a given fill. Off the fill's own
  // luminance rather than a list of which palette colors are bright: the
  // palette is someone else's and can change, the physics cannot. sRGB is
  // gamma-encoded, so the channels are linearized before they are weighted —
  // skipping that reads the greens as far brighter than the eye finds them,
  // and flips bars that were perfectly legible in white.
  function ink(hex) {
    const channels = [1, 3, 5].map(function(at) {
      const channel = parseInt(hex.slice(at, at + 2), 16) / 255
      return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
    })
    const luminance =
      0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

    return luminance > 0.5 ? dash_colors.black : dash_colors.white
  }

  function bar(text, fraction, color) {
    text = text.padEnd(bar_width, " ").slice(0, bar_width)

    const filled = clamp(Math.round(bar_width * fraction), 0, bar_width)

    return " " +
      Text.bgColor(color, Text.color(ink(color), text.slice(0, filled))) +
      Text.bgColor(dash_colors.darkgrey, text.slice(filled)) +
      " "
  }

  // At rest it carries no figure: how full it is IS the answer, and a glance
  // should not be a reckoning. Hovering the row swaps the label for the money —
  // the line itself changes, which is what a TUI does. No overlay, nothing
  // floating over the cell.
  //
  // The bar and the figure deliberately answer DIFFERENT questions: the bar
  // drains as the money goes, the figure says how much has gone. Do not
  // "fix" the number to match the fill.
  function spendBar(row, label, spent_cents, budget_cents) {
    const fraction = budget_cents > 0 ? (budget_cents - spent_cents) / budget_cents : 0
    const spent = money(spent_cents) + " / " + money(budget_cents) + "  "
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  " + label, spent)
        : "  " + label
    )

    return bar(text, fraction <= 0 ? 1 : fraction, roomColor(fraction))
  }

  // Counts UP: it fills as the day's caffeine lands, where the three bars
  // above it drain as the money goes. The color still reads off what is LEFT
  // under the limit, so it turns yellow on the last quarter and red once the
  // limit is passed, same as they do.
  //
  // Drawn blank until the server has said what the limit is — a bar measured
  // against nothing is a shape that means nothing.
  function caffeineBar(row, mg, limit_mg) {
    if (!(limit_mg > 0)) { return blank }

    const remaining = (limit_mg - mg) / limit_mg
    const amount = mg + "mg / " + limit_mg + "mg  "
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  Caffeine", amount)
        : "  Caffeine"
    )

    return bar(text, clamp(mg / limit_mg, 0, 1), roomColor(remaining))
  }

  // Which line the pointer is on. Redrawing replaces the line divs under the
  // cursor, so the next mousemove reports the same row and this exits early
  // rather than looping.
  function hover(row) {
    if (cell.data.hover === row) { return }

    cell.data.hover = row
    render()
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
      spendBar(month_row, "Month", spentOver(month_start, day_of_month), month_budget),
      spendBar(week_row, "Week", spentOver(week_start, 7), week_budget),
      spendBar(today_row, "Today", spentOver(today, 1), day_budget),
      blank,
      blank,
      caffeineBar(
        caffeine_row,
        (cell.data.caffeine || {})[cell.data.day_key] || 0,
        cell.data.caffeine_limit_mg || 0,
      ),
    ]

    cell.lines(lines.slice(0, cell_height))
  }

  cell = Cell.register({
    title: "Spending",
    text: "Loading...",
    data: {
      budget_cents: 0, days: {}, caffeine_limit_mg: 0, caffeine: {},
      day_key: undefined, hover: -1,
    },
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
      // Bound on `.dash-content` rather than the lines themselves: every redraw
      // replaces those, and a handler on a node that is about to be thrown away
      // leaves the hover stuck on whichever row it died over.
      const content = cell.ele.children(".dash-content")
      content.on("mousemove", function(evt) {
        hover($(evt.target).closest(".line").index())
      })
      content.on("mouseleave", function() { hover(-1) })

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
          cell.data.caffeine_limit_mg = data.caffeine_limit_mg || 0
          cell.data.caffeine = data.caffeine || {}
          render()
        },
      })
    },
  })
})()
