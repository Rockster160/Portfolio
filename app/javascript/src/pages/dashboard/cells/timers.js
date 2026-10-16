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

export class Timer {
  constructor(obj = {}) {
    // :local (typed into the omnibar), :deploy (the deploy monitor), :buddy (Byte's)
    this.kind = obj.kind || "local"
    this.id = obj.id || undefined
    this.completed = obj.completed || false
    this.acknowledged = obj.acknowledged || false
    this.errored = obj.errored || false
    this.sha = obj.sha || undefined
    this.message = obj.message || undefined
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

  complete(acknowledge) {
    this.left_ms = 0
    this.left = {
      seconds: 0,
      minutes: 0,
      hours: 0,
      days: 0,
    }
    this.completed = true
    this.acknowledged = !!acknowledge
  }

  error(acknowledge) {
    this.complete(acknowledge)
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

  tick() {
    if (this.completed) return

    const end_time = this.paused_ms == undefined ? this.end_time : Time.msSinceEpoch() + this.paused_ms
    this.left_ms = end_time - Time.msSinceEpoch()
    this.left_ms = this.left_ms <= 0 ? 0 : this.left_ms
    let left = end_time - Time.msSinceEpoch() + Time.second() // Add a second to floor final second
    if (left <= 0) {
      return this.complete()
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
    const timer = this.remaining() + " / " + this.human()
    const text = Text.justify(
      "  " + Text.trunc(name, cell_width - 5 - timer.length),
      timer + "   "
    )
    const fill = this.total_ms > 0 ? (this.total_ms - this.left_ms) / this.total_ms : 1

    const fill_cells = Math.round((cell_width - 2) * fill)
    let color = this.acknowledged ? dash_colors.green : dash_colors.yellow
    if (this.errored) { color = dash_colors.red }
    if (this.paused_ms != undefined && !this.completed) { color = dash_colors.darkgrey }
    const filled = Text.bgColor(color, text.slice(0, fill_cells))
    const empty = Text.bgColor(dash_colors.grey, text.slice(fill_cells, -2))

    return " " + filled + empty + " "
  }
}

(function() {
  var cell = undefined
  // Deploys come and go on their own; only the last few are worth a line.
  const deploy_limit = 5

  function blankCanvas() {
    return Array.from({ length: cell_height }, function() {
      return Array.from({ length: cell_width }, function() { return " " }).join("")
    })
  }

  function saveLocal() {
    localStorage.setItem("timers", JSON.stringify(cell.data.timers))
  }

  function saveDeploys() {
    localStorage.setItem("deploy_timers", JSON.stringify(cell.data.deploy_timers))
  }

  // Every timer on screen, in the order they're drawn — line N+1 is rows[N].
  function rows() {
    return [].concat(cell.data.buddy_timers, cell.data.timers, cell.data.deploy_timers)
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

  function findOrCreateDeploy(sha, message) {
    let existing = cell.data.deploy_timers.find((t) => t.sha === sha)
    if (existing) { return existing }

    let timer = new Timer({
      kind: "deploy",
      name: (message || sha.slice(0, 7)).slice(0, 24),
      sha: sha,
      message: message,
    })
    timer.start.minutes += 2
    timer.start.seconds += 50
    timer.go()
    cell.data.deploy_timers.unshift(timer)
    cell.data.deploy_timers = cell.data.deploy_timers.slice(0, deploy_limit)
    return timer
  }

  function subscribeToDeploys() {
    const monitor = Monitor.subscribe(cell.config.deploy_uuid || "deploy", {
      connected: function() {
        monitor?.resync()
      },
      received: function(data) {
        let json = data.data || {}
        let sha = json.sha
        if (!sha) { return }

        cell.flash()
        let timer = findOrCreateDeploy(sha, json.message)
        let wasCompleted = timer.completed

        if (json.status === "success") {
          timer.complete(true)
          if (!wasCompleted) { victoryBeep() }
        } else if (json.status === "failed") {
          timer.error(true)
          if (!wasCompleted) { failureBeep() }
        }

        saveDeploys()
      },
    })
  }

  // ---- Byte (Buddy) timers --------------------------------------------------

  function buddyChime() {
    beeps([
      [120, 880, 0.15, "sine"],
      [220, 1320, 0.15, "sine"],
    ])
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
    })
    timer.wait = !!t.wait
    if (t.paused_at) {
      timer.paused_ms = t.paused_remaining_ms || 0
    } else if (t.end_at) {
      timer.end_time = Date.parse(t.end_at)
    }
    if (t.fired_at || (timer.end_time && timer.end_time <= Time.msSinceEpoch())) {
      timer.complete(true)
    }
    return timer
  }

  // The countdown just reached zero while on screen: one chime, no alarm. A
  // WAIT is Byte holding the middle of a sequence, not something to announce.
  function tickBuddy() {
    cell.data.buddy_timers.forEach(function(timer) {
      if (timer.completed) { return }

      timer.tick()
      if (timer.completed) {
        timer.acknowledged = true
        if (!timer.wait) { buddyChime() }
      }
    })
  }

  function upsertBuddy(t) {
    const idx = cell.data.buddy_timers.findIndex((timer) => timer.id === t.id)
    // Confirmed (acknowledged in Byte) or archived (cancelled) — it's done.
    const done = t.archived_at || (t.confirmed_at && !t.started_at && !t.fired_at)
    if (done) {
      if (idx >= 0) { cell.data.buddy_timers.splice(idx, 1) }
      return
    }

    const timer = buddyTimer(t)
    if (idx >= 0) {
      const prev = cell.data.buddy_timers[idx]
      // Its own tick already rang it — the server's fire is the same moment, late.
      if (prev.completed && timer.completed) { return }
      cell.data.buddy_timers[idx] = timer
    } else {
      cell.data.buddy_timers.push(timer)
    }
  }

  async function hydrateBuddy() {
    try {
      const data = await buddyApi("/buddy/timers", "GET")
      cell.data.buddy_page_id = data.page_id
      cell.data.buddy_timers = (data.timers || []).map(buddyTimer)
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

        if (data.reason === "archived") { t.archived_at = t.archived_at || true }
        upsertBuddy(t)
      },
    })
  }

  // The DELETE is a request: the line stays until the server says it's gone.
  async function cancelBuddy(timer) {
    try {
      await buddyApi(`/buddy/timers/${timer.id}`, "DELETE")
      upsertBuddy({ id: timer.id, archived_at: true })
    } catch (e) {
      console.warn("[dashboard] Byte timer cancel failed", e)
    }
  }

  // ---- cancel ---------------------------------------------------------------

  function cancel(timer) {
    if (timer.kind === "buddy") {
      return cancelBuddy(timer)
    }
    if (timer.kind === "deploy") {
      cell.data.deploy_timers = cell.data.deploy_timers.filter((t) => t !== timer)
      return saveDeploys()
    }
    cell.data.timers = cell.data.timers.filter((t) => t !== timer)
    saveLocal()
  }

  cell = Cell.register({
    title: "Timers",
    refreshInterval: Time.second() / 2,
    flash: false,
    data: {
      timers: [],
      deploy_timers: [],
      buddy_timers: [],
      buddy_page_id: null,
      on: true,
    },
    commands: {
      clear: function() {
        cell.data.timers = []
        localStorage.removeItem("timers")
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

      if (should_save) { saveLocal() }
    },
    oncontextmenu: function(evt, ctx) {
      if (ctx.lineIndex == null) { return }

      const timer = rows()[ctx.lineIndex - 1]
      if (!timer) { return }

      evt.preventDefault()
      cancel(timer)
      cell.reload()
    },
    onload: function() {
      this.data.timers = Timer.loadFromJSON(JSON.parse(localStorage.getItem("timers") || "[]"))
      const deploys = JSON.parse(localStorage.getItem("deploy_timers") || "[]").filter((t) => t.sha)
      this.data.deploy_timers = Timer.loadFromJSON(deploys).map((timer) => {
        timer.kind = "deploy"
        return timer
      })
      subscribeToDeploys()
      subscribeToBuddy()
    },
    reloader: function() {
      cell.data.on = !cell.data.on
      tickBuddy()
      var should_beep = false
      var lines = blankCanvas()

      rows().slice(0, cell_height-2).forEach(function(timer, idx) {
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
      cell.data.timers.unshift(new_timer)
      saveLocal()
    },
  })
})()
