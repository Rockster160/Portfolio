import { Monitor } from "./monitor"
import { Time } from "./_time"
import { Text } from "../_text"
import { ColorGenerator } from "./color_generator"
import { dash_colors, beep, scaleVal, clamp } from "../vars"

(function() {
  var cell = undefined
  let flashing = undefined
  let flash_on = true

  let flash = function(active) {
    if (active) {
      flashing = flashing || setInterval(renderLines, 400)
    } else {
      clearInterval(flashing)
      flashing = undefined
    }
  }

  let battery_color_scale = ColorGenerator.colorScale((function() {
    let colors = {}
    colors[dash_colors.red]    = 30
    colors[dash_colors.yellow] = 50
    colors[dash_colors.green]  = 95
    return colors
  })())

  let batteryIcon = function(name, icon) {
    let data = cell.data.device_battery[name]
    if (!data) { return "" }
    let val = data.val
    if (!val) { return Text.grey(icon + "?") }
    let char = clamp(Math.round(scaleVal(val, 10, 90, 0, 7)), 0, 7)
    let level = "▁▂▃▄▅▆▇█"[char]
    let reported_at = Time.at(data.time)
    let battery_color = battery_color_scale(val).hex
    if (Time.now() - reported_at > Time.hours(12)) {
      battery_color = dash_colors.grey
    } else if (val == 100) {
      battery_color = dash_colors.rocco
    }
    return icon + Text.color(battery_color, level)
  }

  function shortAgo(timestamp) {
    const now = Math.floor(Date.now() / 1000)
    const at = parseInt(timestamp)
    if (isNaN(at)) { return timestamp }
    const elapsed = now - at

    const secondsInMinute = 60
    const secondsInHour = 3600

    if (elapsed < secondsInMinute) {
      return `${elapsed}s`
    } else if (elapsed < secondsInHour) {
      const minutes = Math.floor(elapsed / secondsInMinute)
      return `${minutes}m`
    } else {
      const hours = Math.floor(elapsed / secondsInHour)
      return `${hours > 99 ? "XX" : hours}h`
    }
  }

  let renderLines = function() {
    let lines = []
    let first_row = []
    first_row.push(cell.data.loading ? "[ico ti ti-fa-spinner ti-spin]" : "")
    if (cell.data?.garage?.timestamp < Time.ago(Time.hour)) { cell.data.garage.state = "unknown" }

    if ("state" in (cell.data?.garage || {})) {
      if (cell.data.garage.state == "open") {
        flash(false)
        first_row.push(Text.orange("[ico ti ti-mdi-garage_open]"))
      } else if (cell.data.garage.state == "closed") {
        flash(false)
        first_row.push(Text.green("[ico ti ti-mdi-garage]"))
      } else if (cell.data.garage.state == "between") {
        flash(true)
        if (flash_on = !flash_on) {
          first_row.push(Text.yellow("[ico ti ti-mdi-garage_open]"))
          if (cell.data.sound) {
            beep(100, 350, 0.02, "square")
          }
        } else {
          first_row.push(Text.yellow("  "))
        }
      } else {
        flash(false)
        first_row.push(Text.grey(" [ico ti ti-mdi-garage]? "))
      }
      first_row.push(shortAgo(cell.data.garage.timestamp / 1000))
    } else {
      flash(false)
      first_row.push(Text.grey(" [ico ti ti-mdi-garage]? "))
    }

    if (cell.data.camera) {
      [
        "Doorbell",
        "Driveway",
        "Backyard",
        "Storage",
      ].forEach(location => {
        const data = cell.data.camera[location] || { at: "?", type: "?" }
        let typeIcon = undefined
        const locIcon = {
          Doorbell: "[ico ti ti-mdi-door]",
          Driveway: "[ico ti ti-fa-car]",
          Backyard: "[ico ti ti-fae-plant]",
          Storage:  "[ico ti ti-fa-dropbox]",
        }[location]
        switch (data.type) {
          case "person": typeIcon = Text.lblue; break;
          case "pet": typeIcon = Text.purple; break;
          case "vehicle": typeIcon = Text.yellow; break;
          case "motion": typeIcon = Text.grey; break;
          default: typeIcon = Text.red
        }
        const time = shortAgo(data.at) || Text.red("--")

        if (locIcon) {
          first_row.push(typeIcon(` ${locIcon}${time}`))
        }
      })
    }

    lines.push(Text.center(first_row.join("")))

    cell.data.devices?.forEach(function(device) {
      let mode_color = dash_colors.grey
      switch (device.current_mode) {
        case "cool": mode_color = dash_colors.lblue; break;
        case "heat": mode_color = dash_colors.orange; break;
        case "off": mode_color = dash_colors.grey; break;
      }
      let name = device.name + ":"
      let current = device.current_temp + "°"
      let goal = Text.color(mode_color, "[" + (device.cool_set || device.heat_set || "off") + "°]")
      let on = null
      if (device.status == "cooling") {
        on = Emoji.snowflake + Emoji.dash
      }
      if (device.status == "heating") {
        on = Emoji.fire + Emoji.dash
      }

      lines.push(Text.center([name, current, goal, on].join(" ")))
    })

    let battery_icons = {
      Phone:  "[ico ti ti-fa-mobile_phone]",
      Watch:  "[ico ti ti-oct-watch]",
      iPad:   "[ico ti ti-mdi-tablet_ipad]",
      Pencil: "[ico ti ti-mdi-pencil]",
    }
    let battery_line = []
    for (let [name, icon] of Object.entries(battery_icons)) {
      // Check last updated
      battery_line.push(batteryIcon(name, icon))
    }
    lines.push(Text.center(battery_line.join(" ")))

    if (cell.data.amz_updates) {
      cell.data.amz_updates.forEach(function(order, idx) {
        let delivery = Text.grey("?")
        let name = order.name || Text.grey("?")

        if (order.errors?.length > 0) {
          name = Text.red(name)
        }

        if (order.delivered) {
          delivery = Text.green("✓")
        } else if (order.date) {
          delivery = Text.magenta(order.date.toLocaleString("en-us", { weekday: "short", month: "short", day: "numeric" }))

          let delivery_date = order.date.getTime()
          if (Time.beginningOfDay() > delivery_date) {
            delivery = Text.orange("Delayed?")
          } else if (Time.beginningOfDay() + Time.day() > delivery_date) {
            delivery = Text.green(order.time_range ? order.time_range : "Today")
          } else if (Time.beginningOfDay() + Time.days(2) > delivery_date) {
            delivery = Text.yellow("Tomorrow")
          } else if (Time.beginningOfDay() + Time.days(6) > delivery_date) {
            delivery = Text.blue(order.date.toLocaleString("en-us", { weekday: "short" }))
          }
        }

        lines.push(Text.justify((idx + 1) + ". " + name, delivery))
      })
    }

    cell.lines(lines)
  }
  setInterval(renderLines, 1000)

  let getGarage = function() {
    cell.recent_garage = false
    cell.garage_socket.send({ request: "get" })

    // If no response within 10 seconds, forget the current state
    clearTimeout(cell.garage_timeout)
    cell.garage_timeout = setTimeout(function() {
      cell.garage_socket.send({ request: "get" })
      console.log("Timed out waiting for garage response");
      cell.data.garage.state = "unknown"
      renderLines()
    }, Time.seconds(10))
  }

  let subscribeWebsockets = function() {
    cell.amz_socket = new CellWS(
      cell,
      Server.socket("AmzUpdatesChannel", function(msg) {
        this.flash()

        let data = []
        msg.forEach(order_data => {
          let order = order_data
          if (!order_data.delivery_date) { return }

          let [year, month, day, ...tz] = order_data.delivery_date.split(/-| /)
          let date = new Date(0)
          date.setFullYear(year, parseInt(month) - 1, day)
          if (order_data.time_range) {
            let meridian = order_data.time_range.match(/([^\d]*?)$/)[1]
            let hour = parseInt(order_data.time_range.match(/(\d+)[^\d]*?$/)[1])
            if (meridian == "pm") { hour += 12 }
            date.setHours(hour)
          }
          order.date = date

          data.push(order)
        })
        this.data.amz_updates = data.sort((a, b) => {
          // delivered status takes priority
          if (b.delivered - a.delivered !== 0) {
            return b.delivered - a.delivered;
          }
          return a.date - b.date
        })
        renderLines()
      })
    )
    cell.amz_socket.send({ action: "request" })
    cell.device_battery_socket = new CellWS(
      cell,
      Server.socket("DeviceBatteryChannel", function(msg) {
        this.flash()

        if (msg.Phone) { cell.data.device_battery.Phone = msg.Phone }
        if (msg.iPad) { cell.data.device_battery.iPad = msg.iPad }
        if (msg.Watch) { cell.data.device_battery.Watch = msg.Watch }
        if (msg.Pencil) { cell.data.device_battery.Pencil = msg.Pencil }

        renderLines()
      })
    )
    cell.device_battery_socket.send({ action: "request" })

    cell.garage_socket = Monitor.subscribe("garage", {
      connected: function() {
        console.log("socket Connected");
        setTimeout(function() {
          cell.garage_socket.send({ request: "get" })
        }, 1000)
        // can also set the arrow?
        // this.send({ request: "open" })
        // this.send({ request: "close" })
        // this.send({ request: "toggle" })
      },
      disconnected: function() {
        console.log("socket Disconnected");
        cell.data.garage.state = "unknown"
        renderLines()
      },
      received: function(data) {
        clearTimeout(cell.garage_timeout)
        cell.flash()
        if (data.loading) {
        } else {
          cell.data.camera = data.data?.camera || {}
          cell.data.garage.timestamp = data.timestamp * 1000
          let msg = data.result || ""
          if (msg.includes("[ico mdi-garage font-size: 100px; color: green;]")) {
            cell.data.garage.state = "closed"
          } else if (msg.includes("yellow; animation: 1s infinite blink")) {
            cell.data.garage.state = "between"
          } else if (msg.includes("[ico mdi-garage_open font-size: 100px; color: orange;]")) {
            cell.data.garage.state = "open"
          } else {
            cell.data.garage.state = "unknown"
          }
          renderLines()
        }
      },
    })

    cell.nest_socket = new CellWS(
      cell,
      Server.socket("NestChannel", function(msg) {
        this.flash()

        if (msg.failed) {
          this.data.loading = false
          this.data.failed = true
          clearInterval(this.data.nest_timer) // Don't try anymore until we manually update
          renderLines()
          return
        } else {
          this.data.failed = false
        }
        if (msg.loading) {
          this.data.loading = true
          renderLines()
          return
        }

        this.data.loading = false
        this.data.devices = msg.devices

        renderLines()
      })
    )
    cell.nest_socket.send({ action: "command", settings: "update" })
    this.data.nest_timer = setInterval(function() {
      cell.nest_socket.send({ action: "command", settings: "update" })
    }, Time.minutes(10))
  }

  cell = Cell.register({
    title: "Home",
    refreshInterval: Time.hour(),
    wrap: false,
    flash: false,
    data: {
      sound: true,
      device_battery: {},
      garage: { state: "unknown", timestamp: 0 },
      camera: { Backyard: {}, Driveway: {}, Doorbell: {}, Storage: {} },
    },
    onload: subscribeWebsockets,
    reloader: function() {
      getGarage()
      renderLines()
      // Update times? "1 minute ago", etc...
    },
    started: function() {
      cell.amz_socket.reopen()
      cell.device_battery_socket.reopen()
      cell.nest_socket.reopen()
    },
    stopped: function() {
      cell.amz_socket.close()
      cell.device_battery_socket.close()
      cell.nest_socket.close()
    },
    commands: {
      quiet: function() {
        cell.data.sound = !cell.data.sound
      },
      open: function(idx) {
        if (idx) {
          let order = cell.data.amz_updates[parseInt(idx)]
          order?.email_ids?.forEach(id => window.open(`https://ardesian.com/emails/${id}`, "_blank"))
        }
      },
    },
    command: function(msg) {
      if (msg.trim() == "o") {
        window.open(cell.config.google_api_url, "_blank")
      } else if (/^-?\d+/.test(msg) && parseInt(msg.match(/\d+/)[0]) < 30) {
        var num = parseInt(msg.match(/\d+/)[0])
        let order = this.data.amz_updates[num - 1]

        if (/^-\d+/.test(msg)) { // Use - to remove item
          cell.amz_socket.send({ action: "change", order_id: order.order_id, item_id: order.item_id, remove: true })
        } else if (/^\d+\s*$/.test(msg)) { // No words means open the order
          let url = "https://www.amazon.com/gp/your-account/order-details?orderID="
          window.open(url + order.order_id.replace("#", ""), "_blank")
        } else { // Rename the order
          cell.amz_socket.send({ action: "change", order_id: order.order_id, item_id: order.item_id, rename: msg.replace(/^\d+ /, "") })
        }
      } else if (/^add\b/i.test(msg)) { // Add item to AMZ deliveries
        cell.amz_socket.send({ action: "change", add: msg })
      } else if (/\b(open|close|toggle|garage)\b/.test(msg)) { // open/close
        cell.garage_socket.send({ channel: "garage", request: msg.match(/\b(open|close|toggle)\b/)[0] })
      } else { // Assume AC control
        cell.nest_socket.send({ action: "command", settings: msg })
      }
    }
  })
})()
