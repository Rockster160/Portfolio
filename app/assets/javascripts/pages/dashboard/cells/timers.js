(function() {
  var cell = undefined, cell_width = 32, cell_height = 9
  function blankCanvas() {
    return Array.from({ length: cell_height }, function() {
      return Array.from({ length: cell_width }, function() { return " " }).join("")
    })
  }

  //if you have another AudioContext class use that one, as some browsers have a limit
  var audioCtx = new (window.AudioContext || window.webkitAudioContext || window.audioContext)

  //All arguments are optional:

  //duration of the tone in milliseconds. Default is 500
  //frequency of the tone in hertz. default is 440
  //volume of the tone. Default is 1, off is 0.
  //type of tone. Possible values are sine, square, sawtooth, triangle, and custom. Default is sine.
  //callback to use on end of tone
  function beep(duration, frequency, volume, type, callback) {
    var oscillator = audioCtx.createOscillator()
    var gainNode = audioCtx.createGain()

    oscillator.connect(gainNode)
    gainNode.connect(audioCtx.destination)

    if (volume) { gainNode.gain.value = volume }
    if (frequency) { oscillator.frequency.value = frequency }
    if (type) { oscillator.type = type }
    if (callback) { oscillator.onended = callback }

    oscillator.start(audioCtx.currentTime)
    oscillator.stop(audioCtx.currentTime + ((duration || 500) / 1000))
  }

  Timer = function(obj) {
    obj = obj || {}
    this.completed = obj.completed || false
    this.acknowledged = obj.acknowledged || false
    this.start = obj.start || {
      seconds: 0,
      minutes: 0,
      hours:   0,
      days:    0,
    }
    // this.seconds = obj.seconds || 0
    // this.minutes = obj.minutes || 0
    // this.hours = obj.hours || 0
    // this.days = obj.days || 0
    this.left_ms = obj.left_ms || 0
    this.total_ms = obj.total_ms || 0
    this.left = obj.left || {
      seconds: 0,
      minutes: 0,
      hours:   0,
      days:    0,
    }
    this.end_time = obj.end_time || undefined
    this.name = obj.name || undefined
  }
  Timer.loadFromJSON = function(timers_array) {
    return timers_array.map(function(timer_data) {
      return new Timer(timer_data)
    })
  }
  Timer.save = function() {
    // Only save the last 10?
    // Sort/order by finish time?
    // Reset timers
    // Remove timers?
    localStorage.setItem("timers", JSON.stringify(cell.data.timers))
  }
  Timer.prototype.notify = function() {
    return this.completed && !this.acknowledged
  }
  Timer.prototype.complete = function() {
    this.completed = true
    this.acknowledged = false
  }
  Timer.prototype.save = function() {
    var ms = 0
    ms += this.start.seconds * Time.seconds()
    ms += this.start.minutes * Time.minutes()
    ms += this.start.hours * Time.hours()
    ms += this.start.days * Time.days()
    this.total_ms = ms
    this.end_time = ms + Time.msSinceEpoch()
    if (ms == 0) { return }

    cell.data.timers.unshift(this)
    Timer.save()
  }
  Timer.prototype.tick = function() {
    if (this.completed) { return }

    this.left_ms = this.end_time - Time.msSinceEpoch()
    this.left_ms = this.left_ms <= 0 ? 0 : this.left_ms
    var left = this.end_time - Time.msSinceEpoch() + Time.second() // Add a second to floor final second
    if (left <= 0) {
      this.left = {
        seconds: 0,
        minutes: 0,
        hours: 0,
        days: 0,
      }

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
  Timer.prototype.human = function() {
    return [[this.start.days, "d"], [this.start.hours, "h"], [this.start.minutes, "m"], [this.start.seconds, "s"]].map(function(chunk) {
      if (chunk[0] == 0) { return null }
      return chunk.join("")
    }).filter(function(str) { return str }).join(" ")
  }
  Timer.prototype.remaining = function() {
    var show_rest = false
    return [this.left.days, this.left.hours, this.left.minutes, this.left.seconds].map(function(dur, idx) {
      if (dur > 0) { show_rest = true }
      if (idx >= 3) { show_rest = true } // Always show seconds
      return show_rest ? String(dur).padStart(2, "0") : null
    }).filter(function(str) { return str }).join(":")
  }
  Timer.prototype.render = function() {
    this.tick()
    var name = this.name ? this.name + ":" : ""
    var timer = this.remaining() + " / " + this.human()
    var text = Text.justify("  " + Text.trunc(name, cell_width - 5 - timer.length), timer + "   ")
    var fill = (this.total_ms - this.left_ms) / this.total_ms

    var fill_cells = Math.round((cell_width - 2) * fill)
    var color = this.acknowledged ? dash_colors.green : dash_colors.yellow
    var filled = Text.bgColor(color, text.slice(0, fill_cells))
    var empty = Text.bgColor(dash_colors.grey, text.slice(fill_cells, -2))

    return " " + filled + empty + " "
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

      if (should_save) { Timer.save() }
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
        if (/\d+m/.test(part)) {
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

      new_timer.save(this)
    },
  })
})()
