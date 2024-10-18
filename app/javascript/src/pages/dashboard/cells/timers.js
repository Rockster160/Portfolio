import { Text } from "../_text"
import { Time } from "./_time"
import { dash_colors, beep } from "../vars"

let cell_width = 32, cell_height = 9

export class Timer {
  constructor(obj = {}) {
    this.completed = obj.completed || false
    this.acknowledged = obj.acknowledged || false
    this.error = false
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
    this.error = true
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

    this.left_ms = this.end_time - Time.msSinceEpoch()
    this.left_ms = this.left_ms <= 0 ? 0 : this.left_ms
    let left = this.end_time - Time.msSinceEpoch() + Time.second() // Add a second to floor final second
    if (left <= 0) {
      return this.complete()
    }

    this.left.days = Math.floor(left / Time.days())
    left = left % Time.days()

    this.left.hours = Math.floor(left / Time.hours())
    left = left % Time.hours()

    this.left.minutes = Math.floor(left / Time.minutes())
    left = left % Time.minutes()

    this.left.seconds = Math.floor(left / Time.seconds())
    left = left % Time.seconds()
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
    const fill = (this.total_ms - this.left_ms) / this.total_ms

    const fill_cells = Math.round((cell_width - 2) * fill)
    let color = this.acknowledged ? dash_colors.green : dash_colors.yellow
    if (this.error) { color = dash_colors.red }
    const filled = Text.bgColor(color, text.slice(0, fill_cells))
    const empty = Text.bgColor(dash_colors.grey, text.slice(fill_cells, -2))

    return " " + filled + empty + " "
  }
}

(function() {
  var cell = undefined
  function blankCanvas() {
    return Array.from({ length: cell_height }, function() {
      return Array.from({ length: cell_width }, function() { return " " }).join("")
    })
  }

  cell = Cell.register({
    title: "Timers",
    refreshInterval: Time.second() / 2,
    flash: false,
    data: {
      timers: [],
      on: true,
    },
    commands: {
      cancel: function(name) {
      },
      restart: function(name) {
      },
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

      if (should_save) {
        localStorage.setItem("timers", JSON.stringify(cell.data.timers))
      }
    },
    onload: function() {
      this.data.timers = Timer.loadFromJSON(JSON.parse(localStorage.getItem("timers") || "[]"))
    },
    reloader: function() {
      cell.data.on = !cell.data.on
      var should_beep = false
      var lines = blankCanvas()

      this.data.timers.slice(0, cell_height-2).forEach(function(timer, idx) {
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
      localStorage.setItem("timers", JSON.stringify(cell.data.timers))
    },
  })
})()
