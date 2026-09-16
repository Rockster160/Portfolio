import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors, clamp } from "../vars"

// Health bars for the money: everything there is against what it is meant to
// last on, then how much is left on the month, the week (Monday to Sunday) and
// today. Each bar carries its own clock — a ☼ on the cell for how much of THAT
// bar's range is left — so money draining faster than the clock reads as a
// fill ending short of its ☼. That is the thing this cell
// exists to show, and it is a SHAPE, not a sum. Nothing carries a number at
// rest; a glance should not be a reckoning. Hover a bar and its own line spells
// the figures out, in place.
//
// The server sends DAILY BUCKETS, not the three totals, so the sums happen
// here against the browser's own clock. That is what makes a dashboard left
// open overnight roll onto the new day at 3am without anything being pushed to
// it — nothing writes to the bank at 3am to say the day changed.
//
// Purchases over $500 arrive in `large_days`, apart from the rest, and no bar
// draws them: rent landing on the 1st is planned money, not the 1st and its
// week being blown. What they cost comes off the MONTH'S budget instead, so the
// month, week and day allowances all shrink evenly to make room for them.
//
// The Claude bars are the same reading for the plan's rate limits: what is
// left of the 5-hour session and of the week, against how much of each window
// is left. The local status line reports them (see
// ~/.claude/hooks/usage-report.sh) and they ride this payload as `claude`.
//
// The Caffeine bar at the bottom is the odd one out: it counts UP, filling as
// the day's milligrams land rather than draining as they go, so its marker
// counts up too. Its buckets arrive in the same payload for the same reason —
// one cell, one broadcast.
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
  // and only these answer to it. Bars that are one reading stack with nothing
  // between them; the gaps made them look like unrelated ones. The blanks that
  // are left separate the GROUPS — the money, Claude, the caffeine.
  const balance_row = 0
  const month_row = 1
  const week_row = 2
  const today_row = 3
  const session_row = 5
  const claude_week_row = 6
  const caffeine_row = 8

  // How long each of the plan's windows runs. The server only says when one
  // RESETS, so where it began is counted back from that.
  const claude_windows = {
    five_hour: Time.hours(5),
    seven_day: Time.days(7),
  }

  const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

  function perceivedDate(date) {
    const day = new Date(date.getTime())
    if (day.getHours() < rollover_hour) { day.setDate(day.getDate() - 1) }
    day.setHours(0, 0, 0, 0)
    return day
  }

  // An ISO date as local midnight. `new Date("2026-09-11")` is UTC midnight,
  // which in Denver is the evening before.
  function localDate(iso) {
    const [year, month, day] = iso.split("-").map(Number)
    return new Date(year, month - 1, day)
  }

  function dateKey(date) {
    return [
      date.getFullYear(),
      String(date.getMonth() + 1).padStart(2, "0"),
      String(date.getDate()).padStart(2, "0"),
    ].join("-")
  }

  // The perceived day `date` falls on, from its 3am to the next one.
  function dayStart(date) {
    const day = new Date(date.getTime())
    day.setHours(rollover_hour, 0, 0, 0)
    return day
  }

  function addDays(date, count) {
    const day = new Date(date.getTime())
    day.setDate(day.getDate() + count)
    return day
  }

  // How much of [from, to) is still ahead of `now`, 0..1. Off the wall clock
  // rather than whole days, so a marker creeps across its bar as the range
  // passes instead of jumping a day at a time.
  function remainingOf(from, to, now) {
    return clamp((to - now) / (to - from), 0, 1)
  }

  // "5pm", "4:10pm". The week's reset adds the day: it is days away, and a
  // bare time reads as today.
  function clock(date, with_day) {
    const hours = date.getHours() % 12 || 12
    const minutes = date.getMinutes()
    const time = hours + (minutes ? ":" + String(minutes).padStart(2, "0") : "") +
      (date.getHours() < 12 ? "am" : "pm")

    return with_day ? weekdays[date.getDay()] + " " + time : time
  }

  // `count` perceived days starting at `from`. A day nobody spent on has no
  // bucket, and a missing bucket is zero — which is what it was.
  function spentOver(from, count, days) {
    days = days || cell.data.days || {}
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

  // `mark` is where on the bar its clock says the fill should end, as a
  // fraction, or undefined for a bar with no clock to read. It is a whole
  // character, not a hairline: the fill moves a cell at a time, so a line
  // claimed a precision the bar does not have. It sits on the cell that would
  // be the LAST one filled if the fill were exactly on pace, rounded the same
  // way the fill is — on pace, the ☼ is the fill's final cell.
  //
  // It takes the cell outright, letter or not. The label is known at a glance
  // and the position is the reading. Not while the row is hovered, though:
  // then the row is spelling out figures, and a ☼ over a digit would change
  // the number.
  function bar(row, text, fraction, color, mark) {
    text = text.padEnd(bar_width, " ").slice(0, bar_width)

    const filled = clamp(Math.round(bar_width * fraction), 0, bar_width)

    function paint(from, to) {
      const fill_to = clamp(filled, from, to)
      return Text.bgColor(color, Text.color(ink(color), text.slice(from, fill_to))) +
        Text.bgColor(dash_colors.darkgrey, text.slice(fill_to, to))
    }

    if (mark === undefined || cell.data.hover === row) {
      return " " + paint(0, bar_width) + " "
    }

    const at = clamp(Math.round(bar_width * clamp(mark, 0, 1)) - 1, 0, bar_width - 1)
    const under = at < filled ? color : dash_colors.darkgrey
    // Grey, never the label's ink: it is a different kind of thing from the
    // words on the bar, and reads as one where it lands on them.
    const marker = Text.bgColor(under, Text.color(dash_colors.grey, "☼"))

    return " " + paint(0, at) + marker + paint(at + 1, bar_width) + " "
  }

  // At rest it carries no figure: how full it is IS the answer, and a glance
  // should not be a reckoning. Hovering the row swaps the label for the money —
  // the line itself changes, which is what a TUI does. No overlay, nothing
  // floating over the cell.
  //
  // The bar and the figure deliberately answer DIFFERENT questions: the bar
  // drains as the money goes, the figure says how much has gone. Do not
  // "fix" the number to match the fill.
  function spendBar(row, label, spent_cents, budget_cents, mark) {
    const fraction = budget_cents > 0 ? (budget_cents - spent_cents) / budget_cents : 0
    const spent = money(spent_cents) + " / " + money(budget_cents) + "  "
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  " + label, spent)
        : "  " + label
    )

    return bar(row, text, fraction <= 0 ? 1 : fraction, roomColor(fraction), mark)
  }

  // Everything there is — the home cell's figure — against the goal it is meant
  // to hold. Its marker is how much of the goal's stretch of calendar is left,
  // so a fill ending short of it is money running out before the date does, at
  // a straight line from the goal to nothing on the last day.
  //
  // Drawn blank without a balance: a total missing an account is a wrong
  // number, and a bar of it is a wrong shape.
  function balanceBar(row, now_ms) {
    const cents = cell.data.balance_cents
    const goal = cell.data.balance_goal || {}
    if (typeof cents !== "number" || !(goal.cents > 0) || !goal.from || !goal.through) {
      return blank
    }

    const fraction = cents / goal.cents
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  Balance", money(cents) + " / " + money(goal.cents) + "  ")
        : "  Balance"
    )
    const mark = remainingOf(
      dayStart(localDate(goal.from)).getTime(),
      dayStart(addDays(localDate(goal.through), 1)).getTime(),
      now_ms,
    )

    return bar(row, text, fraction <= 0 ? 1 : clamp(fraction, 0, 1), roomColor(fraction), mark)
  }

  // Drains like the money: the fill is what is LEFT of the window, and the
  // marker is how much of the window's time is left. The figure on hover is
  // what has been USED and when it resets, which is the question a person at
  // the limit is actually asking.
  //
  // Drawn blank until a report has arrived. A window whose reset has already
  // passed has started over, so it is drawn with all of it left and no marker:
  // the next one only begins with the next use, and there is no clock to read
  // until that has been reported.
  function claudeBar(row, label, key, now) {
    const limit = (cell.data.claude || {})[key] || {}
    if (typeof limit.used !== "number" || !limit.resets_at) { return blank }

    const resets = new Date(limit.resets_at * 1000)
    const lapsed = resets <= now
    const used = lapsed ? 0 : limit.used
    const remaining = (100 - used) / 100
    const figure = (lapsed ? "reset" : used + "% · " + clock(resets, key === "seven_day")) + "  "
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  " + label, figure)
        : "  " + label
    )
    const mark = (
      lapsed
        ? undefined
        : remainingOf(resets - claude_windows[key], resets.getTime(), now.getTime())
    )

    return bar(row, text, remaining <= 0 ? 1 : remaining, roomColor(remaining), mark)
  }

  // Counts UP: it fills as the day's caffeine lands, where the three bars
  // above it drain as the money goes. The color still reads off what is LEFT
  // under the limit, so it turns yellow on the last quarter and red once the
  // limit is passed, same as they do.
  //
  // Drawn blank until the server has said what the limit is — a bar measured
  // against nothing is a shape that means nothing.
  function caffeineBar(row, mg, limit_mg, mark) {
    if (!(limit_mg > 0)) { return blank }

    const remaining = (limit_mg - mg) / limit_mg
    const amount = mg + "mg / " + limit_mg + "mg  "
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  Caffeine", amount)
        : "  Caffeine"
    )

    return bar(row, text, clamp(mg / limit_mg, 0, 1), roomColor(remaining), mark)
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

    const day_of_month = today.getDate()
    const month_start = new Date(today.getTime())
    month_start.setDate(1)
    const month_end = new Date(today.getFullYear(), today.getMonth() + 1, 1)
    const in_month = addDays(month_end, -1).getDate()

    // Only THIS month's large purchases: last month's rent stops coming off
    // the budget at the turn of the month by itself.
    const large = spentOver(month_start, in_month, cell.data.large_days || {})
    const month_budget = Math.max((cell.data.budget_cents || 0) - large, 0)
    const day_budget = month_budget / in_month
    const week_budget = day_budget * 7

    // getDay() counts from Sunday; the week starts on Monday.
    const week_start = addDays(today, -((today.getDay() + 6) % 7))
    const week_end = addDays(week_start, 7)

    // Every range ends at a 3am, the same rollover the buckets are dated by.
    const now_ms = now.getTime()
    const tomorrow = dayStart(addDays(today, 1)).getTime()
    const month_left = remainingOf(
      dayStart(month_start).getTime(), dayStart(month_end).getTime(), now_ms,
    )
    const week_left = remainingOf(
      dayStart(week_start).getTime(), dayStart(week_end).getTime(), now_ms,
    )
    const today_left = remainingOf(dayStart(today).getTime(), tomorrow, now_ms)

    const lines = [
      balanceBar(balance_row, now_ms),
      spendBar(month_row, "Month", spentOver(month_start, day_of_month), month_budget, month_left),
      spendBar(week_row, "Week", spentOver(week_start, 7), week_budget, week_left),
      spendBar(today_row, "Today", spentOver(today, 1), day_budget, today_left),
      blank,
      claudeBar(session_row, "Claude session", "five_hour", now),
      claudeBar(claude_week_row, "Claude week", "seven_day", now),
      blank,
      caffeineBar(
        caffeine_row,
        (cell.data.caffeine || {})[cell.data.day_key] || 0,
        cell.data.caffeine_limit_mg || 0,
        1 - today_left,
      ),
    ]

    cell.lines(lines.slice(0, cell_height))
  }

  cell = Cell.register({
    title: "Spending",
    text: "Loading...",
    data: {
      budget_cents: 0, balance_cents: undefined, balance_goal: {},
      days: {}, large_days: {}, caffeine_limit_mg: 0, caffeine: {}, claude: {},
      day_key: undefined, hover: -1,
    },
    // Only the clock moves between pushes. Redrawing is free and walks every
    // ☼ along — a cell of the session bar is ten minutes — but a resync
    // runs a Jil task, so it waits for the day to actually have changed.
    refreshInterval: Time.minutes(1),
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
          cell.data.balance_cents = data.balance_cents
          cell.data.balance_goal = data.balance_goal || {}
          cell.data.days = data.days || {}
          cell.data.large_days = data.large_days || {}
          cell.data.caffeine_limit_mg = data.caffeine_limit_mg || 0
          cell.data.caffeine = data.caffeine || {}
          cell.data.claude = data.claude || {}
          render()
        },
      })
    },
  })
})()
