import { Text } from "../_text"
import { Time } from "./_time"
import { dash_colors, beep, beeps } from "../vars"
import { Monitor } from "./monitor"

let cell_width = 32, cell_height = 9

function splitMs(ms) {
  let left = Math.max(0, ms)
  const days = Math.floor(left / Time.days())
  left = left % Time.days()
  const hours = Math.floor(left / Time.hours())
  left = left % Time.hours()
  const minutes = Math.floor(left / Time.minutes())
  left = left % Time.minutes()
  const seconds = Math.floor(left / Time.seconds())

  return { days, hours, minutes, seconds }
}

function parseMs(value) {
  if (value == undefined || value === "") return undefined
  const ms = Date.parse(value)
  return isNaN(ms) ? undefined : ms
}

// 3:41p
function clockTime(ms) {
  const date = new Date(ms)
  let hours = date.getHours()
  const ampm = hours >= 12 ? "p" : "a"
  hours = hours % 12 || 12

  return `${hours}:${String(date.getMinutes()).padStart(2, "0")}${ampm}`
}

export class Timer {
  constructor(obj = {}) {
    // :local (typed into the omnibar), :deploy (the deploy monitor), :buddy (Byte's)
    this.kind = obj.kind || "local"
    this.id = obj.id || undefined
    this.completed = obj.completed || false
    this.acknowledged = obj.acknowledged || false
    this.errored = obj.errored || false
    this.wait = obj.wait || false
    this.sha = obj.sha || undefined
    this.message = obj.message || undefined
    // Shown in place of the duration once it's finished — a deploy's real run time.
    this.note = obj.note || undefined
    this.start = obj.start || {
      seconds: 0,
      minutes: 0,
      hours: 0,
      days: 0,
    }
    this.left_ms = obj.left_ms || 0
    this.total_ms = obj.total_ms || 0
    this.left = obj.left || {
      seconds: 0,
      minutes: 0,
      hours: 0,
      days: 0,
    }
    this.end_time = obj.end_time || undefined
    this.completed_at = obj.completed_at || undefined
    // A paused timer counts nothing down: this is what it will have left when resumed.
    this.paused_ms = obj.paused_ms ?? undefined
    this.name = obj.name || undefined
  }

  static loadFromJSON(timers_array) {
    return timers_array.map((timer_data) => new Timer(timer_data))
  }

  notify() {
    return this.completed && !this.acknowledged
  }

  complete(acknowledge, at) {
    this.left_ms = 0
    this.left = {
      seconds: 0,
      minutes: 0,
      hours: 0,
      days: 0,
    }
    this.completed = true
    this.completed_at = at || this.completed_at || Time.msSinceEpoch()
    this.acknowledged = !!acknowledge
  }

  error(acknowledge, at) {
    this.complete(acknowledge, at)
    this.errored = true
  }

  go() {
    let ms = 0
    ms += this.start.seconds * Time.seconds()
    ms += this.start.minutes * Time.minutes()
    ms += this.start.hours * Time.hours()
    ms += this.start.days * Time.days()
    this.total_ms = ms
    this.end_time = ms + Time.msSinceEpoch()
  }

  // Finished, by the moment it finished. Timers saved before that was tracked
  // fall back to when they were due.
  finishedAt() {
    return this.completed_at || this.end_time || 0
  }

  tick() {
    if (this.completed) return

    const end_time = this.paused_ms == undefined ? this.end_time : Time.msSinceEpoch() + this.paused_ms
    this.left_ms = end_time - Time.msSinceEpoch()
    this.left_ms = this.left_ms <= 0 ? 0 : this.left_ms
    let left = end_time - Time.msSinceEpoch() + Time.second() // Add a second to floor final second
    if (left <= 0) {
      this.left = splitMs(0)
      // A deploy's countdown is only an estimate — it's finished when the deploy says so.
      if (this.kind === "deploy") return

      return this.complete(false, end_time)
    }

    this.left = splitMs(left)
  }

  human() {
    return [
      [this.start.days, "d"],
      [this.start.hours, "h"],
      [this.start.minutes, "m"],
      [this.start.seconds, "s"],
    ].map(chunk => {
      if (chunk[0] === 0) return null
      return chunk.join("")
    }).filter((str) => str).join(" ")
  }

  remaining() {
    let show_rest = false
    return [
      this.left.days,
      this.left.hours,
      this.left.minutes,
      this.left.seconds,
    ]
    .map((dur, idx) => {
      if (dur > 0) show_rest = true
      if (idx >= 3) show_rest = true // Always show seconds
      return show_rest ? String(dur).padStart(2, "0") : null
    })
    .filter((str) => str)
    .join(":")
  }

  render() {
    this.tick()
    const name = this.name ? this.name + ":" : ""
    // A deploy past its estimate keeps running until it reports; it's shown as
    // timed out, counting how far over it has gone.
    const overdue = this.kind === "deploy" && !this.completed && this.left_ms <= 0
    const over = overdue ? splitMs(Time.msSinceEpoch() - this.end_time) : undefined
    const timer = (
      this.completed
        ? [this.note || this.human(), clockTime(this.finishedAt())].join(" ")
        : overdue
          ? `+${over.hours * 60 + over.minutes}:${String(over.seconds).padStart(2, "0")} / ${this.human()}`
          : this.remaining() + " / " + this.human()
    )
    const text = Text.justify(
      "  " + Text.trunc(name, cell_width - 5 - timer.length),
      timer + "   "
    )
    // A running timer drains from full to empty; a deploy is progress, so it
    // fills up, never starting from a bare bar. Once finished, every bar is
    // full in its result color.
    const elapsed = this.total_ms > 0 ? (this.total_ms - this.left_ms) / this.total_ms : 1
    const fill = this.completed ? 1 : (this.kind === "deploy" ? elapsed : 1 - elapsed)

    let fill_cells = Math.round((cell_width - 2) * fill)
    if (this.kind === "deploy") { fill_cells = Math.max(1, fill_cells) }
    let color = this.acknowledged ? dash_colors.green : dash_colors.yellow
    if (this.errored || overdue) { color = dash_colors.red }
    if (this.paused_ms != undefined && !this.completed) { color = dash_colors.darkgrey }
    const filled = Text.bgColor(color, text.slice(0, fill_cells))
    const empty = Text.bgColor(dash_colors.grey, text.slice(fill_cells, -2))

    return " " + filled + empty + " "
  }
}

(function() {
  var cell = undefined
  // Finished timers are kept as a history, newest first; this many are worth keeping.
  const history_limit = 10

  function blankCanvas() {
    return Array.from({ length: cell_height }, function() {
      return Array.from({ length: cell_width }, function() { return " " }).join("")
    })
  }

  // Running first, the one closest to done on top; then everything finished,
  // most recently finished first. Every kind of timer shares the one list.
  function sorted() {
    const running = cell.data.timers.filter((t) => !t.completed)
    const finished = cell.data.timers.filter((t) => t.completed)
    const leftOf = (t) => (t.paused_ms != undefined ? t.paused_ms : t.left_ms)

    running.sort((a, b) => leftOf(a) - leftOf(b))
    finished.sort((a, b) => b.finishedAt() - a.finishedAt())

    return running.concat(finished)
  }

  function save() {
    const list = sorted()
    const running = list.filter((t) => !t.completed)
    const finished = list.filter((t) => t.completed).slice(0, history_limit)
    cell.data.timers = running.concat(finished)
    localStorage.setItem("timers", JSON.stringify(cell.data.timers))
  }

  function remove(timer) {
    cell.data.timers = cell.data.timers.filter((t) => t !== timer)
    save()
  }

  // ---- deploys ------------------------------------------------------------

  function victoryBeep() {
    beeps([
      [100, 1000, 0.1, "sine"], // Short and high-pitched
      [150, 800, 0.2, "sine"], // Slightly longer and lower-pitched
      [300, 1200, 0.4, "sine"], // Even longer and higher-pitched
    ])
  }

  function failureBeep() {
    beeps([
      [200, 600, 0.4, "sine"],
      [200, 500, 0.2, "sine"],
      [150, 400, 0.1, "sine"],
    ])
  }

  // A deploy runs about 2m50s, measured from when it actually started rather
  // than when this page heard about it.
  function findOrCreateDeploy(json) {
    let existing = cell.data.timers.find((t) => t.kind === "deploy" && t.sha === json.sha)
    if (existing) { return existing }

    let timer = new Timer({
      kind: "deploy",
      name: (json.message || json.sha.slice(0, 7)).slice(0, 24),
      sha: json.sha,
      message: json.message,
    })
    timer.start.minutes += 2
    timer.start.seconds += 50
    timer.go()
    const started = parseMs(json.start_time)
    if (started) { timer.end_time = started + timer.total_ms }
    cell.data.timers.push(timer)
    return timer
  }

  function subscribeToDeploys() {
    Monitor.subscribe(cell.config.deploy_uuid || "deploy", {
      connected: function() {
        this.resync()
      },
      received: function(data) {
        let json = data.data || {}
        if (!json.sha) { return }

        cell.flash()
        let timer = findOrCreateDeploy(json)
        let wasCompleted = timer.completed
        let finished = parseMs(json.finish_time)

        if (json.status === "success") {
          timer.note = json.duration || timer.note
          timer.complete(true, finished)
          if (!wasCompleted) { victoryBeep() }
        } else if (json.status === "failed") {
          timer.note = "failed"
          timer.error(true, finished)
          if (!wasCompleted) { failureBeep() }
        }

        save()
      },
    })
  }

  // ---- Byte (Buddy) timers --------------------------------------------------

  // The generic "a timer finished" sound: one soft, low tap. Deliberately
  // nothing like the deploy chimes, which are the only rising melodies here.
  function timerChime() {
    beep(180, 523, 0.08, "triangle")
  }

  async function buddyApi(url, method) {
    const csrfMeta = document.querySelector('meta[name="csrf-token"]')
    const res = await fetch(url, {
      method,
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": csrfMeta ? csrfMeta.getAttribute("content") : "",
      },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    return res.json().catch(() => ({}))
  }

  // A serialized countdown → a Timer. A countdown already past its end when it
  // arrives went off while nobody was watching here, so it lands acknowledged
  // and never chimes.
  function buddyTimer(t) {
    const timer = new Timer({
      kind: "buddy",
      id: t.id,
      name: t.name || "Byte",
      total_ms: t.duration_ms || 0,
      start: splitMs(t.duration_ms || 0),
      wait: !!t.wait,
    })
    if (t.paused_at) {
      timer.paused_ms = t.paused_remaining_ms || 0
    } else if (t.end_at) {
      timer.end_time = parseMs(t.end_at)
    }
    const fired = parseMs(t.fired_at)
    if (fired || (timer.end_time && timer.end_time <= Time.msSinceEpoch())) {
      timer.complete(true, fired || timer.end_time)
    }
    return timer
  }

  function findBuddy(id) {
    return cell.data.timers.find((t) => t.kind === "buddy" && t.id === id)
  }

  // Acknowledging it in Byte or cancelling it once it's rung both leave it in
  // the history; cancelling one still counting down takes it off.
  function applyBuddy(t, reason) {
    const existing = findBuddy(t.id)
    const timer = buddyTimer(t)
    const ended = reason === "archived" || (t.confirmed_at && !t.started_at && !t.fired_at)

    if (ended) {
      if (!existing) { return }
      if (existing.completed) { return save() }
      if (existing.end_time && existing.end_time <= Time.msSinceEpoch()) {
        existing.complete(true, existing.end_time)
        return save()
      }
      return remove(existing)
    }
    if (existing) {
      // Its own tick already rang it — the server's fire is the same moment, late.
      if (existing.completed && timer.completed) { return }
      cell.data.timers[cell.data.timers.indexOf(existing)] = timer
    } else {
      cell.data.timers.push(timer)
    }
    save()
  }

  // The server is the truth for what's still running; the history is ours.
  async function hydrateBuddy() {
    try {
      const data = await buddyApi("/buddy/timers", "GET")
      cell.data.buddy_page_id = data.page_id
      const live = (data.timers || []).map(buddyTimer)
      const ids = live.map((t) => t.id)
      cell.data.timers = cell.data.timers.filter((t) => {
        if (t.kind !== "buddy") return true
        return t.completed && !ids.includes(t.id)
      }).concat(live)
      save()
    } catch (e) {
      console.warn("[dashboard] Byte timers hydrate failed", e)
    }
  }

  function subscribeToBuddy() {
    Monitor.subscribe("timers", {
      connected: function() {
        hydrateBuddy()
      },
      received: function(payload) {
        const data = payload?.data || {}
        const t = data.timer
        if (!t) { return }
        // The person's other timer pages ride the same stream.
        if (cell.data.buddy_page_id == null || t.timer_page_id !== cell.data.buddy_page_id) { return }

        applyBuddy(t, data.reason)
      },
    })
  }

  // ---- ticking --------------------------------------------------------------

  // A typed timer alarms until it's looked at; a Byte timer chimes once.
  function tickAll() {
    let changed = false
    cell.data.timers.forEach(function(timer) {
      if (timer.completed) { return }

      timer.tick()
      if (!timer.completed) { return }

      changed = true
      if (timer.kind === "buddy") {
        timer.acknowledged = true
        if (!timer.wait) { timerChime() }
      }
    })
    if (changed) { save() }
  }

  // ---- cancel ---------------------------------------------------------------

  // A Byte timer's DELETE is a request: the line stays until the server agrees,
  // unless it has already finished and is only history here.
  async function cancel(timer) {
    if (timer.kind !== "buddy") { return remove(timer) }

    try {
      await buddyApi(`/buddy/timers/${timer.id}`, "DELETE")
      remove(timer)
    } catch (e) {
      if (timer.completed) { return remove(timer) }
      console.warn("[dashboard] Byte timer cancel failed", e)
    }
  }

  cell = Cell.register({
    title: "Timers",
    refreshInterval: Time.second() / 2,
    flash: false,
    data: {
      timers: [],
      buddy_page_id: null,
      on: true,
    },
    commands: {
      clear: function() {
        cell.data.timers = cell.data.timers.filter((t) => !t.completed)
        save()
      },
    },
    onlook: function() {
      var should_save = false

      this.data.timers.forEach(function(timer) {
        if (timer.notify()) {
          should_save = true
          timer.acknowledged = true
        }
      })

      if (should_save) { save() }
    },
    oncontextmenu: function(evt, ctx) {
      if (ctx.lineIndex == null) { return }

      const timer = sorted()[ctx.lineIndex - 1]
      if (!timer) { return }

      evt.preventDefault()
      cancel(timer).then(() => cell.reload())
    },
    onload: function() {
      const stored = JSON.parse(localStorage.getItem("timers") || "[]")
      // Deploys used to be kept apart, by the Github cell.
      const deploys = JSON.parse(localStorage.getItem("deploy_timers") || "[]").filter((t) => t.sha)
      deploys.forEach((t) => { t.kind = "deploy" })
      localStorage.removeItem("deploy_timers")

      this.data.timers = Timer.loadFromJSON(stored.concat(deploys))
      save()
      subscribeToDeploys()
      subscribeToBuddy()
    },
    reloader: function() {
      cell.data.on = !cell.data.on
      tickAll()
      var should_beep = false
      var lines = blankCanvas()

      sorted().slice(0, cell_height-2).forEach(function(timer, idx) {
        if (timer.notify()) { should_beep = true }
        lines[idx + 1] = timer.render()
      })

      if (should_beep && cell.data.on) {
        lines = lines.map(function(line, idx) {
          if (idx == 0 || idx == cell_height-1) {
            return Text.bgColor(dash_colors.red, " ".repeat(cell_width))
          }
          line = line.split("")
          line[0] = Text.bgColor(dash_colors.red, " ")
          line[line.length-1] = Text.bgColor(dash_colors.red, " ")
          return line.join("")
        })
        beep(50, 500, 0.05, "square")
      }

      this.lines(lines)
    },
    command: function(text) {
      var new_timer = new Timer()
      var name = text.split(" ").filter(function(part) {
        if (/\d+s/.test(part)) {
          new_timer.start.seconds += parseInt(part.match(/\d+/))
          return false
        }
        if (/\d+m/.test(part) || /\d+\b/.test(part)) {
          new_timer.start.minutes += parseInt(part.match(/\d+/))
          return false
        }
        if (/\d+h/.test(part)) {
          new_timer.start.hours += parseInt(part.match(/\d+/))
          return false
        }
        if (/\d+d/.test(part)) {
          new_timer.start.days += parseInt(part.match(/\d+/))
          return false
        }
        return true
      }).join(" ").trim()
      if (name.length > 0) { new_timer.name = name }

      new_timer.go()
      cell.data.timers.push(new_timer)
      save()
    },
  })
})()
