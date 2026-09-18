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
// The session bar can carry a second mark, a ‼, for where the WEEK runs out
// part way through it — the point past which there is session left and nothing
// to spend it on. It needs an exchange rate between two percentages of
// different sizes, which is measured rather than assumed: `claude.burn` is how
// much of each the reporter has watched go, this week, and their ratio is the
// rate. Until enough of the week has been watched it is not drawn at all.
//
// The Caffeine bar at the bottom is the odd one out: it counts UP, filling as
// the day's milligrams land rather than draining as they go, and it carries no
// ☼ — the fill against the limit is the whole reading. Its buckets arrive in
// the same payload for the same reason — one cell, one broadcast.
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

  // How much of a session the reporter has to have watched before their ratio
  // is worth drawing a ‼ off. Both figures are whole percents, so a handful of
  // reports is mostly rounding; a fifth of a session is not.
  const burn_sample_pct = 20

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

  // Which cell a fraction marks: the one that would be the LAST filled if the
  // fill were exactly there, rounded the same way the fill is.
  function markAt(fraction) {
    return clamp(Math.round(bar_width * clamp(fraction, 0, 1)) - 1, 0, bar_width - 1)
  }

  // `mark` is where on the bar its clock says the fill should end, as a
  // fraction, or undefined for a bar with no clock to read. It is a whole
  // character, not a hairline: the fill moves a cell at a time, so a line
  // claimed a precision the bar does not have. It sits on the cell that would
  // be the LAST one filled if the fill were exactly on pace — on pace, the ☼ is
  // the fill's final cell. `wall` is a second mark on the same footing.
  //
  // It takes the cell outright, letter or not. The label is known at a glance
  // and the position is the reading. Not while the row is hovered, though:
  // then the row is spelling out figures, and a ☼ over a digit would change
  // the number.
  //
  // The color is the same reading as the ☼, so it is decided off the same
  // cells: green while the fill reaches the ☼, yellow once it falls short. A
  // bar with no clock has nothing to be behind, so it stays green unless the
  // caller has its own reason to `warn`. `gone` is red, and drawn FULL: an
  // empty red sliver reads as "nearly out" when it means the opposite.
  function bar(row, text, fraction, mark, gone, warn, wall) {
    text = text.padEnd(bar_width, " ").slice(0, bar_width)

    const filled = clamp(Math.round(bar_width * (gone ? 1 : fraction)), 0, bar_width)
    const target = mark === undefined ? undefined : Math.round(bar_width * clamp(mark, 0, 1))
    const on_pace = target === undefined || filled >= target
    const color = (
      gone
        ? dash_colors.red
        : (on_pace && !warn ? dash_colors.green : dash_colors.yellow)
    )

    function paint(from, to) {
      const fill_to = clamp(filled, from, to)
      return Text.bgColor(color, Text.color(ink(color), text.slice(from, fill_to))) +
        Text.bgColor(dash_colors.darkgrey, text.slice(fill_to, to))
    }

    // Grey, never the label's ink: a mark is a different kind of thing from
    // the words on the bar, and reads as one where it lands on them. On the
    // empty track that is the light grey; on a fill it is the track's own dark
    // grey, which the light one washes out against green, yellow and red alike.
    function markCell(at, glyph) {
      const under = at < filled ? color : dash_colors.darkgrey
      // The clock is grey on whatever it lands on — it is only saying where you
      // are. The wall is red, and red only reads on something dark: on the
      // green fill it is the same brightness as the green (1.06 : 1) and on an
      // exhausted red bar it is the same color outright. So its cell drops to
      // the empty track's own dark — a notch in the fill with a red mark in it,
      // and nothing at all to see where the track is already that color.
      if (glyph === "‼") {
        return Text.bgColor(dash_colors.darkgrey, Text.color(dash_colors.red, glyph))
      }

      const grey = at < filled ? dash_colors.darkgrey : dash_colors.grey
      return Text.bgColor(under, Text.color(grey, glyph))
    }

    const marks = {}
    if (mark !== undefined) { marks[markAt(mark)] = "☼" }
    // Second, so that a week ending exactly where the clock does says the
    // harder of the two things.
    if (wall !== undefined) { marks[markAt(wall)] = "‼" }

    const cells = Object.keys(marks).map(Number).sort(function(a, b) { return a - b })
    if (cells.length === 0 || cell.data.hover === row) {
      return " " + paint(0, bar_width) + " "
    }

    let drawn = ""
    let from = 0
    cells.forEach(function(at) {
      drawn += paint(from, at) + markCell(at, marks[at])
      from = at + 1
    })

    return " " + drawn + paint(from, bar_width) + " "
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

    return bar(row, text, fraction, mark, fraction <= 0)
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

    return bar(row, text, fraction, mark, fraction <= 0)
  }

  // Where the WEEK runs out, measured in session, as a fraction of the session
  // bar — or undefined when there is nothing solid to say.
  //
  // `burn.week / burn.session` is what a percent of session costs in percent of
  // week, watched rather than assumed. What is left of the week, divided by
  // that, is how much session there is anything left to spend on.
  //
  // Undefined until a fifth of a session has been watched THIS week: the totals
  // start over with the week, both figures are whole percents, and a ratio off
  // two or three of them would move the mark around for no reason.
  function weeklyWall(now) {
    const claude = cell.data.claude || {}
    const burn = claude.burn || {}
    const week = claude.seven_day || {}
    const current = typeof week.used === "number" && week.resets_at * 1000 > now
    if (!current || !(burn.session >= burn_sample_pct) || !(burn.week > 0)) { return undefined }

    return ((100 - week.used) / (burn.week / burn.session)) / 100
  }

  // Drains like the money: the fill is what is LEFT of the window, and the ☼
  // is how much of the window's time is left. The figure on hover is what is
  // left too, and when it resets.
  //
  // Only a CURRENT report is drawn as one: a window whose reset has passed has
  // started over, and one that has never been reported is in the same place as
  // far as anyone here can tell. Either way it is taken as all of it left — the
  // next window only starts with the next use, so there is no reset time to
  // show and no clock for a ☼ to read, and the figure says `??` where the time
  // would be. That is what the bar says until a session reports the new one.
  //
  // The session also carries the ‼ for where the week gives out, and only when
  // that falls INSIDE what is left of the session — past the end of the bar it
  // is not a wall, it is just the week outlasting this window, which is the
  // ordinary case and needs no mark.
  function claudeBar(row, label, key, now) {
    const limit = (cell.data.claude || {})[key] || {}
    const resets = limit.resets_at ? new Date(limit.resets_at * 1000) : undefined
    const current = typeof limit.used === "number" && resets !== undefined && resets > now
    const left = current ? 100 - limit.used : 100
    const figure = (current ? left + "% · " + clock(resets, key === "seven_day") : "100% · ??") + "  "
    const text = (
      cell.data.hover === row
        ? Text.justify(bar_width, "  " + label, figure)
        : "  " + label
    )
    const mark = (
      current
        ? remainingOf(resets - claude_windows[key], resets.getTime(), now.getTime())
        : undefined
    )
    const week_out = key === "five_hour" && current ? weeklyWall(now.getTime()) : undefined
    const wall = week_out !== undefined && week_out < left / 100 ? week_out : undefined

    return bar(row, text, left / 100, mark, left <= 0, false, wall)
  }

  // Counts UP: it fills as the day's caffeine lands, where the bars above it
  // drain as the money goes. No ☼: how much of the day has gone says nothing
  // about how much caffeine is fine. Green, yellow from three quarters of the
  // limit, and red once it is reached.
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

    return bar(row, text, mg / limit_mg, undefined, remaining <= 0, remaining <= 0.25)
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
